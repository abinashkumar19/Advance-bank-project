"""Safe deposit lockers - browse available sizes at a branch, rent one
(debits the annual fee immediately), release it later. A simple
availability counter per (branch, size) rather than tracking individual
physical locker numbers - enough to model "sold out" without a full
inventory system."""
import os
import sys
from datetime import date, timedelta
from decimal import Decimal
from typing import List, Literal

from fastapi import APIRouter, FastAPI, HTTPException
from pydantic import BaseModel

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from common.aws_clients import sns_publish, table
from common.service_base import adjust_balance, get_account_or_404, new_id, now_iso, write_audit_log

SNS_TOPIC_ENV = "USER_REGISTERED_TOPIC_ARN"

app = FastAPI(title="VeeraBank Lockers Service", version="1.0.0")
router = APIRouter(prefix="/lockers")
tbl = table("lockers")

LockerSize = Literal["small", "medium", "large"]

# Static demo branch/size catalog with a running availability count.
# Real availability is tracked in-memory here for demo purposes only - a
# production version would need this in DynamoDB with atomic decrements,
# same pattern as accounts.balance.
CATALOG = {
    ("Hyderabad Main", "small"): {"annual_fee": "1500", "available": 8},
    ("Hyderabad Main", "medium"): {"annual_fee": "2500", "available": 5},
    ("Hyderabad Main", "large"): {"annual_fee": "4000", "available": 2},
    ("Bangalore Whitefield", "small"): {"annual_fee": "1500", "available": 6},
    ("Bangalore Whitefield", "medium"): {"annual_fee": "2500", "available": 4},
}


class RentRequest(BaseModel):
    user_id: str
    account_id: str
    branch: str
    size: LockerSize


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@router.get("/")
def root():
    return {"service": "lockers-service", "status": "running"}


@router.get("/availability")
def availability():
    return [{"branch": b, "size": s, **info} for (b, s), info in CATALOG.items()]


@router.post("/rent", status_code=201)
def rent(payload: RentRequest):
    key = (payload.branch, payload.size)
    if key not in CATALOG:
        raise HTTPException(status_code=404, detail=f"No {payload.size} lockers at {payload.branch}")
    if CATALOG[key]["available"] <= 0:
        raise HTTPException(status_code=409, detail="No lockers of that size available at this branch right now")

    account = get_account_or_404(payload.account_id)
    if account["user_id"] != payload.user_id:
        raise HTTPException(status_code=403, detail="You can only rent using your own account")

    fee = Decimal(CATALOG[key]["annual_fee"])
    adjust_balance(payload.account_id, -fee)  # raises 402 if insufficient funds
    CATALOG[key]["available"] -= 1

    item = {
        "id": new_id(),
        "user_id": payload.user_id,
        "account_id": payload.account_id,
        "branch": payload.branch,
        "size": payload.size,
        "annual_fee": str(fee),
        "locker_number": f"{payload.size[0].upper()}{100 + CATALOG[key]['available']}",
        "status": "active",
        "rented_at": now_iso(),
        "renewal_date": (date.today() + timedelta(days=365)).isoformat(),
        "created_at": now_iso(),
    }
    tbl.put_item(Item=item)
    write_audit_log(payload.user_id, "locker_rented", {"locker_id": item["id"], "branch": payload.branch})

    try:
        sns_publish(
            SNS_TOPIC_ENV,
            subject=f"Locker rented at {payload.branch}",
            message={
                "type": "locker_rented",
                "user_id": payload.user_id,
                "summary": f"₹{fee} debited - {payload.size} locker {item['locker_number']} rented at {payload.branch}",
                "locker_id": item["id"],
                "amount": str(fee),
            },
        )
    except Exception as exc:  # noqa: BLE001
        print(f"[lockers] failed to publish notification: {exc}")

    return item


@router.get("/user/{user_id}", response_model=List[dict])
def list_for_user(user_id: str):
    resp = tbl.query(IndexName="user_id-index", KeyConditionExpression="user_id = :u", ExpressionAttributeValues={":u": user_id})
    return sorted(resp.get("Items", []), key=lambda i: i.get("created_at", ""), reverse=True)


@router.patch("/{locker_id}/release")
def release(locker_id: str):
    resp = tbl.get_item(Key={"id": locker_id})
    item = resp.get("Item")
    if not item:
        raise HTTPException(status_code=404, detail="Locker rental not found")
    if item["status"] != "active":
        raise HTTPException(status_code=400, detail=f"Locker is already {item['status']}")

    key = (item["branch"], item["size"])
    if key in CATALOG:
        CATALOG[key]["available"] += 1

    tbl.update_item(Key={"id": locker_id}, UpdateExpression="SET #s = :s", ExpressionAttributeNames={"#s": "status"}, ExpressionAttributeValues={":s": "released"})
    write_audit_log(item["user_id"], "locker_released", {"locker_id": locker_id})
    return {**item, "status": "released"}


app.include_router(router)
