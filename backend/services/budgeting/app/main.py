"""Budgeting - per-category monthly limits the user sets, plus a spend
summary computed by calling transactions-service and bucketing amounts by
category. Categorization is keyword-based against the transaction
description (a real system would tag categories at transaction time, but
transactions-service doesn't carry a category field today - this stays a
best-effort companion to statements/reports rather than rewriting that
service)."""
import os
import re
import sys
from decimal import Decimal
from typing import List

import requests
from fastapi import APIRouter, FastAPI, HTTPException
from pydantic import BaseModel, field_validator

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from common.aws_clients import table
from common.service_base import new_id, now_iso

TRANSACTIONS_SERVICE_URL = os.environ.get("TRANSACTIONS_SERVICE_URL", "http://transactions-svc.veerabank.svc.cluster.local")

app = FastAPI(title="VeeraBank Budgeting Service", version="1.0.0")
router = APIRouter(prefix="/budgeting")
tbl = table("budgeting")  # one item per (user_id, category) limit

CATEGORY_KEYWORDS = {
    "food": ["restaurant", "swiggy", "zomato", "cafe", "food"],
    "shopping": ["amazon", "flipkart", "myntra", "shop", "mall"],
    "utilities": ["electricity", "water", "gas", "broadband", "recharge", "dth", "bill"],
    "transport": ["uber", "ola", "fuel", "petrol", "metro", "cab"],
    "entertainment": ["netflix", "spotify", "prime", "movie", "bookmyshow"],
    "transfer": ["transfer", "sent to", "received from"],
}


def _categorize(description: str) -> str:
    desc = (description or "").lower()
    for category, keywords in CATEGORY_KEYWORDS.items():
        if any(k in desc for k in keywords):
            return category
    return "other"


class SetLimit(BaseModel):
    user_id: str
    category: str
    monthly_limit: Decimal

    @field_validator("monthly_limit")
    @classmethod
    def _non_negative(cls, v):
        if v < 0:
            raise ValueError("monthly_limit cannot be negative")
        return v


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@router.get("/")
def root():
    return {"service": "budgeting-service", "status": "running"}


@router.put("/limits", status_code=200)
def set_limit(payload: SetLimit):
    item_id = f"{payload.user_id}:{payload.category}"
    item = {
        "id": item_id,
        "user_id": payload.user_id,
        "category": payload.category,
        "monthly_limit": payload.monthly_limit,
        "updated_at": now_iso(),
    }
    tbl.put_item(Item=item)
    return item


@router.get("/limits/user/{user_id}", response_model=List[dict])
def get_limits(user_id: str):
    resp = tbl.query(IndexName="user_id-index", KeyConditionExpression="user_id = :u", ExpressionAttributeValues={":u": user_id})
    return resp.get("Items", [])


@router.get("/insights/user/{user_id}")
def insights(user_id: str):
    """Pulls this user's transactions and buckets them by keyword-guessed
    category, then compares each bucket against any limit they've set."""
    try:
        resp = requests.get(f"{TRANSACTIONS_SERVICE_URL}/transactions/user/{user_id}", timeout=8)
        resp.raise_for_status()
        transactions = resp.json()
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=502, detail=f"Could not reach transactions-service: {exc}")

    spend_by_category: dict = {}
    for txn in transactions:
        amount = Decimal(str(txn.get("amount", 0)))
        if amount >= 0:
            continue  # only debits count as "spend"
        category = _categorize(txn.get("description", ""))
        spend_by_category[category] = spend_by_category.get(category, Decimal("0")) + abs(amount)

    limits = {i["category"]: Decimal(str(i["monthly_limit"])) for i in get_limits(user_id)}

    breakdown = []
    for category, spent in sorted(spend_by_category.items(), key=lambda kv: kv[1], reverse=True):
        limit = limits.get(category)
        breakdown.append({
            "category": category,
            "spent": str(spent),
            "limit": str(limit) if limit is not None else None,
            "over_limit": bool(limit is not None and spent > limit),
        })

    return {"user_id": user_id, "total_spend": str(sum(spend_by_category.values()) or Decimal("0")), "breakdown": breakdown}


app.include_router(router)
