"""Forex - currency exchange orders. VeeraBank accounts only ever hold
INR (single-currency, like every other service here), so this doesn't
credit a foreign-currency balance anywhere - it debits INR at a rate and
records the converted foreign amount as an order, the same way a
real forex counter gives you cash/a forex card rather than a foreign bank
account. Rates are static demo data, not a live feed."""
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

app = FastAPI(title="VeeraBank Forex Service", version="1.0.0")
router = APIRouter(prefix="/forex")
tbl = table("forex")

# Static demo rates: units of INR per 1 unit of foreign currency, roughly
# realistic as of early 2026, NOT a live feed. A real integration would
# call an FX rate provider here instead.
RATES_INR_PER_UNIT = {
    "USD": "83.20", "EUR": "90.10", "GBP": "105.40", "AED": "22.65",
    "SGD": "61.80", "AUD": "54.90", "JPY": "0.56",
}

Currency = Literal["USD", "EUR", "GBP", "AED", "SGD", "AUD", "JPY"]


class ConvertRequest(BaseModel):
    user_id: str
    account_id: str
    currency: Currency
    foreign_amount: Decimal  # amount of the foreign currency being bought

    @field_validator("foreign_amount")
    @classmethod
    def _positive(cls, v):
        if v <= 0:
            raise ValueError("foreign_amount must be greater than zero")
        return v


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@router.get("/")
def root():
    return {"service": "forex-service", "status": "running"}


@router.get("/rates")
def rates():
    return RATES_INR_PER_UNIT


@router.post("/convert", status_code=201)
def convert(payload: ConvertRequest):
    account = get_account_or_404(payload.account_id)
    if account["user_id"] != payload.user_id:
        raise HTTPException(status_code=403, detail="You can only convert using your own account")

    rate = Decimal(RATES_INR_PER_UNIT[payload.currency])
    inr_amount = (payload.foreign_amount * rate).quantize(Decimal("0.01"))

    adjust_balance(payload.account_id, -inr_amount)  # raises 402 if insufficient funds

    item = {
        "id": new_id(),
        "user_id": payload.user_id,
        "account_id": payload.account_id,
        "currency": payload.currency,
        "foreign_amount": payload.foreign_amount,
        "rate": str(rate),
        "inr_amount": inr_amount,
        "status": "completed",
        "created_at": now_iso(),
    }
    tbl.put_item(Item=item)
    write_audit_log(payload.user_id, "forex_converted", {"order_id": item["id"], "currency": payload.currency, "inr_amount": str(inr_amount)})

    try:
        sns_publish(
            SNS_TOPIC_ENV,
            subject=f"₹{inr_amount} converted to {payload.foreign_amount} {payload.currency}",
            message={
                "type": "forex_converted",
                "user_id": payload.user_id,
                "summary": f"₹{inr_amount} debited to buy {payload.foreign_amount} {payload.currency} @ ₹{rate}",
                "order_id": item["id"],
                "amount": str(inr_amount),
            },
        )
    except Exception as exc:  # noqa: BLE001
        print(f"[forex] failed to publish notification: {exc}")

    return item


@router.get("/user/{user_id}", response_model=List[dict])
def list_for_user(user_id: str):
    resp = tbl.query(IndexName="user_id-index", KeyConditionExpression="user_id = :u", ExpressionAttributeValues={":u": user_id})
    return sorted(resp.get("Items", []), key=lambda i: i.get("created_at", ""), reverse=True)


app.include_router(router)
