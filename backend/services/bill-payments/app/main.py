"""Bill payments - electricity, mobile recharge, DTH, broadband. Distinct
from the generic `payments` service: this one models a biller_type +
consumer/account number pair (like real BBPS billers do) rather than a
free-form payee, and always debits real account balance immediately."""
import os
import sys
from decimal import Decimal
from typing import List, Literal

from fastapi import APIRouter, FastAPI, HTTPException
from pydantic import BaseModel, field_validator

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from common.aws_clients import sns_publish, table
from common.service_base import adjust_balance, get_account_or_404, new_id, now_iso, write_audit_log

SNS_TOPIC_ENV = "USER_REGISTERED_TOPIC_ARN"

app = FastAPI(title="VeeraBank Bill Payments Service", version="1.0.0")
router = APIRouter(prefix="/bill-payments")
tbl = table("bill-payments")

BillerType = Literal["electricity", "mobile", "dth", "broadband", "gas", "water"]

# Static demo billers per type - a real integration would call out to a
# BBPS aggregator API to fetch this list and validate the consumer number.
BILLERS = {
    "electricity": ["State Electricity Board", "Torrent Power", "Adani Electricity"],
    "mobile": ["Airtel", "Jio", "Vi", "BSNL"],
    "dth": ["Tata Play", "Dish TV", "Airtel Digital TV"],
    "broadband": ["ACT Fibernet", "Airtel Xstream", "JioFiber"],
    "gas": ["Indraprastha Gas", "Mahanagar Gas"],
    "water": ["Municipal Water Board"],
}


class PayBill(BaseModel):
    user_id: str
    account_id: str
    biller_type: BillerType
    biller_name: str
    consumer_number: str
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
    return {"service": "bill-payments-service", "status": "running"}


@router.get("/billers")
def list_billers():
    return BILLERS


@router.post("/pay", status_code=201)
def pay(payload: PayBill):
    account = get_account_or_404(payload.account_id)
    if account["user_id"] != payload.user_id:
        raise HTTPException(status_code=403, detail="You can only pay bills from your own account")
    if payload.biller_name not in BILLERS.get(payload.biller_type, []):
        raise HTTPException(status_code=400, detail=f"Unknown {payload.biller_type} biller: {payload.biller_name}")

    adjust_balance(payload.account_id, -payload.amount)  # raises 402 if insufficient funds

    item = {
        "id": new_id(),
        "user_id": payload.user_id,
        "account_id": payload.account_id,
        "biller_type": payload.biller_type,
        "biller_name": payload.biller_name,
        "consumer_number": payload.consumer_number,
        "amount": payload.amount,
        "status": "paid",
        "created_at": now_iso(),
    }
    tbl.put_item(Item=item)
    write_audit_log(payload.user_id, "bill_paid", {"bill_id": item["id"], "biller": payload.biller_name, "amount": str(payload.amount)})

    try:
        sns_publish(
            SNS_TOPIC_ENV,
            subject=f"₹{payload.amount} paid to {payload.biller_name}",
            message={
                "type": "bill_paid",
                "user_id": payload.user_id,
                "summary": f"₹{payload.amount} bill payment to {payload.biller_name} ({payload.biller_type}) successful",
                "bill_id": item["id"],
                "amount": str(payload.amount),
            },
        )
    except Exception as exc:  # noqa: BLE001
        print(f"[bill-payments] failed to publish notification: {exc}")

    return item


@router.get("/user/{user_id}", response_model=List[dict])
def list_for_user(user_id: str):
    resp = tbl.query(IndexName="user_id-index", KeyConditionExpression="user_id = :u", ExpressionAttributeValues={":u": user_id})
    return sorted(resp.get("Items", []), key=lambda i: i.get("created_at", ""), reverse=True)


@router.get("/{bill_id}")
def get_bill(bill_id: str):
    resp = tbl.get_item(Key={"id": bill_id})
    item = resp.get("Item")
    if not item:
        raise HTTPException(status_code=404, detail="Bill payment not found")
    return item


app.include_router(router)
