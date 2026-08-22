"""Virtual cards - one-time-use or merchant-locked cards, always tied to
a real account (checked via cards-service pattern, not duplicated here:
this service doesn't own account debits itself, spend against a virtual
card is expected to flow through payments/bill-payments the same way a
real card would - this service is the card lifecycle only: issue, lock,
freeze, spend-count enforcement for single-use cards).

Same masked-number safety rule as cards-service: full card_number is only
ever returned once, at issuance."""
import os
import random
import sys
from datetime import datetime, timedelta, timezone
from typing import List, Literal, Optional

from fastapi import APIRouter, FastAPI, HTTPException
from pydantic import BaseModel

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from common.aws_clients import sns_publish, table
from common.service_base import get_account_or_404, new_id, now_iso, write_audit_log

SNS_TOPIC_ENV = "USER_REGISTERED_TOPIC_ARN"

app = FastAPI(title="VeeraBank Virtual Cards Service", version="1.0.0")
router = APIRouter(prefix="/virtual-cards")
tbl = table("virtual-cards")

CardMode = Literal["single_use", "merchant_locked", "standard"]


class VirtualCardCreate(BaseModel):
    user_id: str
    account_id: str
    mode: CardMode = "standard"
    merchant_name: Optional[str] = None  # required when mode == merchant_locked
    spend_limit: Optional[str] = None


def _luhn_check_digit(digits: str) -> str:
    total = 0
    for i, d in enumerate(reversed(digits)):
        n = int(d)
        if i % 2 == 0:
            n *= 2
            if n > 9:
                n -= 9
        total += n
    return str((10 - (total % 10)) % 10)


def _generate_card_number() -> str:
    body = "4539" + "".join(str(random.randint(0, 9)) for _ in range(11))  # distinct virtual-card BIN range
    return body + _luhn_check_digit(body)


def _mask(item: dict) -> dict:
    out = dict(item)
    out.pop("card_number", None)
    return out


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@router.get("/")
def root():
    return {"service": "virtual-cards-service", "status": "running"}


@router.post("/", status_code=201)
def create_card(payload: VirtualCardCreate):
    account = get_account_or_404(payload.account_id)
    if account["user_id"] != payload.user_id:
        raise HTTPException(status_code=403, detail="You can only create virtual cards on your own account")
    if payload.mode == "merchant_locked" and not payload.merchant_name:
        raise HTTPException(status_code=400, detail="merchant_name is required for a merchant_locked card")

    number = _generate_card_number()
    now = datetime.now(timezone.utc)
    expiry = now + timedelta(days=30 if payload.mode == "single_use" else 365 * 3)

    item = {
        "id": new_id(),
        "user_id": payload.user_id,
        "account_id": payload.account_id,
        "mode": payload.mode,
        "merchant_name": payload.merchant_name,
        "spend_limit": payload.spend_limit,
        "card_number": number,
        "card_number_masked": f"{number[:4]} •••• •••• {number[-4:]}",
        "cvv": "".join(str(random.randint(0, 9)) for _ in range(3)),
        "expiry_month": expiry.month,
        "expiry_year": expiry.year,
        "status": "active",
        "used": False,  # relevant for single_use only
        "created_at": now_iso(),
    }
    tbl.put_item(Item=item)
    write_audit_log(payload.user_id, "virtual_card_issued", {"card_id": item["id"], "mode": payload.mode})

    try:
        sns_publish(
            SNS_TOPIC_ENV,
            subject=f"New virtual card issued ({payload.mode.replace('_', ' ')})",
            message={
                "type": "virtual_card_created",
                "user_id": payload.user_id,
                "summary": f"New {payload.mode.replace('_', ' ')} virtual card issued, ending in {number[-4:]}",
                "card_id": item["id"],
                "card_number_masked": item["card_number_masked"],
            },
        )
    except Exception as exc:  # noqa: BLE001
        print(f"[virtual-cards] failed to publish notification: {exc}")

    return item  # the ONLY response that ever includes the full card_number


@router.get("/user/{user_id}", response_model=List[dict])
def list_for_user(user_id: str):
    resp = tbl.query(IndexName="user_id-index", KeyConditionExpression="user_id = :u", ExpressionAttributeValues={":u": user_id})
    return [_mask(i) for i in sorted(resp.get("Items", []), key=lambda i: i.get("created_at", ""), reverse=True)]


@router.get("/{card_id}")
def get_card(card_id: str):
    resp = tbl.get_item(Key={"id": card_id})
    item = resp.get("Item")
    if not item:
        raise HTTPException(status_code=404, detail="Virtual card not found")
    return _mask(item)


@router.patch("/{card_id}/freeze")
def freeze(card_id: str):
    return _set_status(card_id, "frozen")


@router.patch("/{card_id}/unfreeze")
def unfreeze(card_id: str):
    return _set_status(card_id, "active")


@router.delete("/{card_id}", status_code=204)
def void(card_id: str):
    _set_status(card_id, "voided")


def _set_status(card_id: str, status: str):
    resp = tbl.get_item(Key={"id": card_id})
    item = resp.get("Item")
    if not item:
        raise HTTPException(status_code=404, detail="Virtual card not found")
    tbl.update_item(Key={"id": card_id}, UpdateExpression="SET #s = :s", ExpressionAttributeNames={"#s": "status"}, ExpressionAttributeValues={":s": status})
    write_audit_log(item["user_id"], f"virtual_card_{status}", {"card_id": card_id})
    return _mask({**item, "status": status})


@router.post("/{card_id}/mark-used")
def mark_used(card_id: str):
    """Called by whatever service processes a spend against this card
    (payments/bill-payments) once a single_use card has been charged."""
    resp = tbl.get_item(Key={"id": card_id})
    item = resp.get("Item")
    if not item:
        raise HTTPException(status_code=404, detail="Virtual card not found")
    if item["mode"] != "single_use":
        return _mask(item)  # no-op for non-single-use cards
    tbl.update_item(Key={"id": card_id}, UpdateExpression="SET used = :t, #s = :s", ExpressionAttributeNames={"#s": "status"}, ExpressionAttributeValues={":t": True, ":s": "used"})
    return _mask({**item, "used": True, "status": "used"})


app.include_router(router)
