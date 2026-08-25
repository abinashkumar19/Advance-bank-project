"""Webhooks - lets a user (or, more realistically, a developer building on
top of VeeraBank) register a URL to receive HTTP POSTs for specific event
types (transfer_debit, transfer_credit, card_created, bill_paid, ...) -
the same event vocabulary notification-writer Lambda already uses.

SCOPE NOTE: this service owns subscription management + delivery
attempts/log + a manual /test endpoint. It does NOT yet automatically fire
on every real event across every other service - that would mean either
(a) every other service also calling this service after each action, or
(b) subscribing this service to the shared SNS topic the same way
notification-writer Lambda does. Both are straightforward follow-ups once
you decide which; deliver_event() below is written so either wiring can
call it directly."""
import os
import sys
from typing import List, Optional

import requests
from fastapi import APIRouter, FastAPI, HTTPException
from pydantic import BaseModel, HttpUrl

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from common.aws_clients import table
from common.service_base import new_id, now_iso, write_audit_log

app = FastAPI(title="VeeraBank Webhooks Service", version="1.0.0")
router = APIRouter(prefix="/webhooks")
subscriptions_tbl = table("webhooks")
deliveries_tbl = table("webhook-deliveries")

KNOWN_EVENT_TYPES = [
    "user_registered", "transfer_debit", "transfer_credit", "card_created",
    "bill_paid", "insurance_purchased", "goal_completed", "goal_contribution",
    "recurring_payment_executed",
]


class SubscriptionCreate(BaseModel):
    user_id: str
    url: HttpUrl
    event_types: List[str]
    secret: Optional[str] = None  # included as X-VeeraBank-Signature header on delivery, for the receiver to verify


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@router.get("/")
def root():
    return {"service": "webhooks-service", "status": "running"}


@router.get("/event-types")
def event_types():
    return KNOWN_EVENT_TYPES


@router.post("/subscriptions", status_code=201)
def create_subscription(payload: SubscriptionCreate):
    unknown = [e for e in payload.event_types if e not in KNOWN_EVENT_TYPES]
    if unknown:
        raise HTTPException(status_code=400, detail=f"Unknown event_types: {unknown}")

    item = {
        "id": new_id(),
        "user_id": payload.user_id,
        "url": str(payload.url),
        "event_types": payload.event_types,
        "secret": payload.secret,
        "status": "active",
        "created_at": now_iso(),
    }
    subscriptions_tbl.put_item(Item=item)
    write_audit_log(payload.user_id, "webhook_subscribed", {"subscription_id": item["id"], "url": item["url"]})
    return item


@router.get("/subscriptions/user/{user_id}", response_model=List[dict])
def list_subscriptions(user_id: str):
    resp = subscriptions_tbl.query(IndexName="user_id-index", KeyConditionExpression="user_id = :u", ExpressionAttributeValues={":u": user_id})
    return resp.get("Items", [])


@router.delete("/subscriptions/{subscription_id}", status_code=204)
def delete_subscription(subscription_id: str):
    resp = subscriptions_tbl.get_item(Key={"id": subscription_id})
    if not resp.get("Item"):
        raise HTTPException(status_code=404, detail="Subscription not found")
    subscriptions_tbl.delete_item(Key={"id": subscription_id})


@router.patch("/subscriptions/{subscription_id}/pause")
def pause_subscription(subscription_id: str):
    return _set_subscription_status(subscription_id, "paused")


@router.patch("/subscriptions/{subscription_id}/resume")
def resume_subscription(subscription_id: str):
    return _set_subscription_status(subscription_id, "active")


def _set_subscription_status(subscription_id: str, status: str) -> dict:
    resp = subscriptions_tbl.get_item(Key={"id": subscription_id})
    item = resp.get("Item")
    if not item:
        raise HTTPException(status_code=404, detail="Subscription not found")
    subscriptions_tbl.update_item(
        Key={"id": subscription_id},
        UpdateExpression="SET #s = :s",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={":s": status},
    )
    return {**item, "status": status}


def _deliver_to(subscription: dict, event_type: str, payload: dict) -> dict:
    headers = {"Content-Type": "application/json", "X-VeeraBank-Event": event_type}
    if subscription.get("secret"):
        headers["X-VeeraBank-Signature"] = subscription["secret"]  # demo-only: a real impl would HMAC-sign the body instead of sending the raw secret

    delivery = {
        "id": new_id(),
        "subscription_id": subscription["id"],
        "user_id": subscription["user_id"],
        "event_type": event_type,
        "url": subscription["url"],
        "created_at": now_iso(),
    }
    try:
        resp = requests.post(subscription["url"], json=payload, headers=headers, timeout=8)
        delivery["status"] = "delivered" if resp.ok else "failed"
        delivery["response_code"] = resp.status_code
    except Exception as exc:  # noqa: BLE001
        delivery["status"] = "failed"
        delivery["response_code"] = None
        delivery["error"] = str(exc)

    deliveries_tbl.put_item(Item=delivery)
    return delivery


def deliver_event(user_id: str, event_type: str, payload: dict) -> List[dict]:
    """Called by other in-cluster code (or wired into the shared SNS topic
    later - see module docstring) to fan an event out to every matching,
    active subscription this user has."""
    resp = subscriptions_tbl.query(IndexName="user_id-index", KeyConditionExpression="user_id = :u", ExpressionAttributeValues={":u": user_id})
    matching = [s for s in resp.get("Items", []) if s.get("status") == "active" and event_type in s.get("event_types", [])]
    return [_deliver_to(s, event_type, payload) for s in matching]


class TestDeliveryRequest(BaseModel):
    event_type: str = "user_registered"
    payload: dict = {}


@router.post("/subscriptions/{subscription_id}/test")
def test_delivery(subscription_id: str, body: TestDeliveryRequest):
    resp = subscriptions_tbl.get_item(Key={"id": subscription_id})
    subscription = resp.get("Item")
    if not subscription:
        raise HTTPException(status_code=404, detail="Subscription not found")
    return _deliver_to(subscription, body.event_type, {"test": True, **body.payload})


@router.get("/deliveries/user/{user_id}", response_model=List[dict])
def list_deliveries(user_id: str):
    resp = deliveries_tbl.query(IndexName="user_id-index", KeyConditionExpression="user_id = :u", ExpressionAttributeValues={":u": user_id})
    return sorted(resp.get("Items", []), key=lambda i: i.get("created_at", ""), reverse=True)


app.include_router(router)
