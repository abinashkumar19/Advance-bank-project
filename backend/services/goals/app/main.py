"""Savings goals - set a target amount + optional target date, then
contribute toward it. Each contribution actually debits the linked
account (money really moves, same as fixed-deposits funding), so
`current_amount` is a real running total, not a display-only number."""
import os
import sys
from datetime import date
from decimal import Decimal
from typing import List, Optional

from fastapi import APIRouter, FastAPI, HTTPException
from pydantic import BaseModel, field_validator

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from common.aws_clients import sns_publish, table
from common.service_base import adjust_balance, get_account_or_404, new_id, now_iso, write_audit_log

SNS_TOPIC_ENV = "USER_REGISTERED_TOPIC_ARN"

app = FastAPI(title="VeeraBank Goals Service", version="1.0.0")
router = APIRouter(prefix="/goals")
tbl = table("goals")


class GoalCreate(BaseModel):
    user_id: str
    account_id: str
    name: str
    target_amount: Decimal
    target_date: Optional[str] = None  # YYYY-MM-DD

    @field_validator("target_amount")
    @classmethod
    def _positive(cls, v):
        if v <= 0:
            raise ValueError("target_amount must be greater than zero")
        return v


class Contribution(BaseModel):
    amount: Decimal

    @field_validator("amount")
    @classmethod
    def _positive(cls, v):
        if v <= 0:
            raise ValueError("amount must be greater than zero")
        return v


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@router.get("/")
def root():
    return {"service": "goals-service", "status": "running"}


@router.post("/", status_code=201)
def create_goal(payload: GoalCreate):
    get_account_or_404(payload.account_id)
    item = {
        "id": new_id(),
        "user_id": payload.user_id,
        "account_id": payload.account_id,
        "name": payload.name,
        "target_amount": payload.target_amount,
        "current_amount": Decimal("0"),
        "target_date": payload.target_date,
        "status": "in_progress",
        "created_at": now_iso(),
    }
    tbl.put_item(Item=item)
    write_audit_log(payload.user_id, "goal_created", {"goal_id": item["id"], "name": payload.name})
    return item


@router.get("/user/{user_id}", response_model=List[dict])
def list_for_user(user_id: str):
    resp = tbl.query(IndexName="user_id-index", KeyConditionExpression="user_id = :u", ExpressionAttributeValues={":u": user_id})
    return sorted(resp.get("Items", []), key=lambda i: i.get("created_at", ""), reverse=True)


@router.get("/{goal_id}")
def get_goal(goal_id: str):
    resp = tbl.get_item(Key={"id": goal_id})
    item = resp.get("Item")
    if not item:
        raise HTTPException(status_code=404, detail="Goal not found")
    return item


@router.post("/{goal_id}/contribute")
def contribute(goal_id: str, payload: Contribution):
    resp = tbl.get_item(Key={"id": goal_id})
    item = resp.get("Item")
    if not item:
        raise HTTPException(status_code=404, detail="Goal not found")
    if item["status"] != "in_progress":
        raise HTTPException(status_code=400, detail=f"Goal is {item['status']}, can't contribute")

    adjust_balance(item["account_id"], -payload.amount)  # raises 402 if insufficient funds

    new_total = Decimal(item["current_amount"]) + payload.amount
    reached = new_total >= Decimal(item["target_amount"])
    tbl.update_item(
        Key={"id": goal_id},
        UpdateExpression="SET current_amount = :c, #s = :s",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={":c": new_total, ":s": "completed" if reached else "in_progress"},
    )
    write_audit_log(item["user_id"], "goal_contribution", {"goal_id": goal_id, "amount": str(payload.amount)})

    updated = {**item, "current_amount": new_total, "status": "completed" if reached else "in_progress"}

    try:
        summary = f"Goal '{item['name']}' reached! 🎉" if reached else f"₹{payload.amount} added to '{item['name']}'"
        sns_publish(
            SNS_TOPIC_ENV,
            subject=summary,
            message={
                "type": "goal_completed" if reached else "goal_contribution",
                "user_id": item["user_id"],
                "summary": summary,
                "goal_id": goal_id,
                "amount": str(payload.amount),
            },
        )
    except Exception as exc:  # noqa: BLE001
        print(f"[goals] failed to publish notification: {exc}")

    return updated


@router.delete("/{goal_id}", status_code=204)
def cancel_goal(goal_id: str):
    resp = tbl.get_item(Key={"id": goal_id})
    if not resp.get("Item"):
        raise HTTPException(status_code=404, detail="Goal not found")
    tbl.update_item(Key={"id": goal_id}, UpdateExpression="SET #s = :s", ExpressionAttributeNames={"#s": "status"}, ExpressionAttributeValues={":s": "cancelled"})


app.include_router(router)
