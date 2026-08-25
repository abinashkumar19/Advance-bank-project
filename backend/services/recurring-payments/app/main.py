"""Recurring payments (standing instructions) - rent, SIPs, EMI autopay.
Each instruction has a `next_run_date`; running it debits the account,
advances next_run_date by its frequency, and publishes a notification -
same debit pattern as a one-off payment, just repeatable.

NOTE ON SCHEDULING: this service exposes POST /run-due, which finds every
active instruction whose next_run_date has passed and executes it. Nothing
calls that endpoint automatically yet - wiring up an EventBridge scheduled
rule -> Lambda (or a cron sidecar) to hit it daily is a follow-up
infrastructure task, not something this service does on its own."""
import os
import sys
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal
from typing import List, Literal, Optional

from fastapi import APIRouter, FastAPI, HTTPException
from pydantic import BaseModel, field_validator

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from common.aws_clients import sns_publish, table
from common.service_base import adjust_balance, get_account_or_404, new_id, now_iso, write_audit_log

SNS_TOPIC_ENV = "USER_REGISTERED_TOPIC_ARN"  # shared general-purpose notifications topic

app = FastAPI(title="VeeraBank Recurring Payments Service", version="1.0.0")
router = APIRouter(prefix="/recurring-payments")
tbl = table("recurring-payments")

Frequency = Literal["daily", "weekly", "monthly"]


class CreateInstruction(BaseModel):
    user_id: str
    account_id: str
    payee_name: str
    amount: Decimal
    frequency: Frequency
    start_date: Optional[str] = None  # YYYY-MM-DD, defaults to today
    note: str = ""

    @field_validator("amount")
    @classmethod
    def _positive(cls, v):
        if v <= 0:
            raise ValueError("amount must be greater than zero")
        return v


def _advance(d: date, frequency: Frequency) -> date:
    if frequency == "daily":
        return d + timedelta(days=1)
    if frequency == "weekly":
        return d + timedelta(weeks=1)
    # monthly - naive but sufficient for a dev/demo app (no calendar-month library dependency)
    month = d.month + 1
    year = d.year + (1 if month > 12 else 0)
    month = 1 if month > 12 else month
    day = min(d.day, 28)
    return date(year, month, day)


def _notify(user_id: str, summary: str, extra: dict):
    try:
        sns_publish(SNS_TOPIC_ENV, subject=summary, message={"type": "recurring_payment_executed", "user_id": user_id, "summary": summary, **extra})
    except Exception as exc:  # noqa: BLE001
        print(f"[recurring-payments] failed to publish notification: {exc}")


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@router.get("/")
def root():
    return {"service": "recurring-payments-service", "status": "running"}


@router.post("/", status_code=201)
def create_instruction(payload: CreateInstruction):
    get_account_or_404(payload.account_id)
    start = payload.start_date or date.today().isoformat()

    item = {
        "id": new_id(),
        "user_id": payload.user_id,
        "account_id": payload.account_id,
        "payee_name": payload.payee_name,
        "amount": payload.amount,
        "frequency": payload.frequency,
        "next_run_date": start,
        "note": payload.note,
        "status": "active",
        "created_at": now_iso(),
        "last_run_at": None,
        "run_count": 0,
    }
    tbl.put_item(Item=item)
    write_audit_log(payload.user_id, "recurring_payment_created", {"instruction_id": item["id"], "payee": payload.payee_name})
    return item


@router.get("/user/{user_id}", response_model=List[dict])
def list_for_user(user_id: str):
    resp = tbl.query(IndexName="user_id-index", KeyConditionExpression="user_id = :u", ExpressionAttributeValues={":u": user_id})
    return sorted(resp.get("Items", []), key=lambda i: i.get("created_at", ""), reverse=True)


@router.get("/{instruction_id}")
def get_instruction(instruction_id: str):
    resp = tbl.get_item(Key={"id": instruction_id})
    item = resp.get("Item")
    if not item:
        raise HTTPException(status_code=404, detail="Recurring payment not found")
    return item


@router.patch("/{instruction_id}/pause")
def pause(instruction_id: str):
    return _set_status(instruction_id, "paused")


@router.patch("/{instruction_id}/resume")
def resume(instruction_id: str):
    return _set_status(instruction_id, "active")


@router.delete("/{instruction_id}", status_code=204)
def cancel(instruction_id: str):
    _set_status(instruction_id, "cancelled")


def _set_status(instruction_id: str, status: str):
    resp = tbl.get_item(Key={"id": instruction_id})
    item = resp.get("Item")
    if not item:
        raise HTTPException(status_code=404, detail="Recurring payment not found")
    tbl.update_item(Key={"id": instruction_id}, UpdateExpression="SET #s = :s", ExpressionAttributeNames={"#s": "status"}, ExpressionAttributeValues={":s": status})
    return {**item, "status": status}


def _execute_one(item: dict) -> dict:
    try:
        adjust_balance(item["account_id"], -Decimal(item["amount"]))
    except HTTPException as e:
        if e.status_code == 402:
            # Insufficient funds - leave the instruction active, don't advance
            # next_run_date, so it retries on the next /run-due call.
            write_audit_log(item["user_id"], "recurring_payment_failed", {"instruction_id": item["id"], "reason": "insufficient_funds"})
            return {**item, "last_run_status": "failed_insufficient_funds"}
        raise

    next_date = _advance(date.fromisoformat(item["next_run_date"]), item["frequency"])
    tbl.update_item(
        Key={"id": item["id"]},
        UpdateExpression="SET next_run_date = :n, last_run_at = :t, run_count = run_count + :one",
        ExpressionAttributeValues={":n": next_date.isoformat(), ":t": now_iso(), ":one": 1},
    )
    write_audit_log(item["user_id"], "recurring_payment_executed", {"instruction_id": item["id"], "payee": item["payee_name"], "amount": str(item["amount"])})
    _notify(item["user_id"], f"₹{item['amount']} auto-debited for {item['payee_name']}", {"instruction_id": item["id"], "amount": str(item["amount"])})
    return {**item, "next_run_date": next_date.isoformat(), "last_run_status": "success"}


@router.post("/{instruction_id}/run")
def run_one(instruction_id: str):
    """Manually trigger a single instruction now, regardless of next_run_date - useful for testing."""
    resp = tbl.get_item(Key={"id": instruction_id})
    item = resp.get("Item")
    if not item:
        raise HTTPException(status_code=404, detail="Recurring payment not found")
    if item["status"] != "active":
        raise HTTPException(status_code=400, detail=f"Instruction is {item['status']}, not active")
    return _execute_one(item)


@router.post("/run-due")
def run_due():
    """Scan every active instruction and execute the ones whose
    next_run_date has arrived. Call this from a scheduler (not built here -
    see module docstring)."""
    today = date.today().isoformat()
    resp = tbl.scan()
    due = [i for i in resp.get("Items", []) if i.get("status") == "active" and i.get("next_run_date", "9999-99-99") <= today]
    results = [_execute_one(item) for item in due]
    return {"executed": len(results), "results": results}


app.include_router(router)
