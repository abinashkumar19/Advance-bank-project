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
import uuid
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from typing import List, Literal, Optional

from fastapi import APIRouter, FastAPI, HTTPException
from pydantic import BaseModel, field_validator

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from common.aws_clients import dynamodb_client, raw_table_name, sns_publish, table, to_ddb_item
from common.service_base import adjust_balance, get_account_or_404, new_id, now_iso, write_audit_log

SNS_TOPIC_ENV = "USER_REGISTERED_TOPIC_ARN"
accounts_table = table("accounts")

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


class PayWithCardRequest(BaseModel):
    """Pay using ONLY the virtual card number - no account_id, no user_id
    for the SENDER. This mirrors how you'd actually use a virtual card at
    checkout: you have the 16-digit number (shown once at creation, see
    create_card below), you don't have or need to know which account or
    user it belongs to - the linked source account is looked up from the
    card itself.

    to_account_number IS required though: this is money moving to another
    real VeeraBank account (same public account-number-based lookup
    transfers-service uses), not a black hole - both sides of the ledger
    move atomically, see _pay_atomic below."""
    card_number: str
    to_account_number: str
    amount: Decimal
    merchant_name: Optional[str] = None  # if set on a merchant_locked card, must match

    @field_validator("amount")
    @classmethod
    def _positive(cls, v):
        if v <= 0:
            raise ValueError("amount must be greater than zero")
        return v


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


def _find_by_card_number(card_number: str) -> dict:
    """Card number isn't the table's primary key (id is), and isn't
    indexed with its own GSI - this table stays small at demo scale, so a
    filtered Scan is fine here, same tradeoff already made in
    admin-analytics for its cross-table summaries. Worth adding a GSI on
    card_number if this table ever grows large in a real deployment."""
    resp = tbl.scan(FilterExpression="card_number = :n", ExpressionAttributeValues={":n": card_number})
    items = resp.get("Items", [])
    if not items:
        raise HTTPException(status_code=404, detail="Card number not recognized")
    return items[0]


def _get_account_by_number(account_number: str) -> dict:
    resp = accounts_table.query(
        IndexName="account_number-index",
        KeyConditionExpression="account_number = :n",
        ExpressionAttributeValues={":n": account_number},
        Limit=1,
    )
    items = [i for i in resp.get("Items", []) if i.get("record_type") == "account"]
    if not items:
        raise HTTPException(status_code=404, detail="No account with that account number")
    return items[0]


@router.post("/pay")
def pay_with_card(payload: PayWithCardRequest):
    card = _find_by_card_number(payload.card_number.replace(" ", ""))

    if card["status"] == "voided":
        raise HTTPException(status_code=400, detail="This card has been voided")
    if card["status"] == "frozen":
        raise HTTPException(status_code=400, detail="This card is frozen - unfreeze it before using")
    if card["mode"] == "single_use" and card.get("used"):
        raise HTTPException(status_code=400, detail="This single-use card has already been used")
    if card["mode"] == "merchant_locked" and (not payload.merchant_name or card.get("merchant_name") != payload.merchant_name):
        raise HTTPException(status_code=403, detail=f"This card can only be used at {card['merchant_name']}")

    from_account_id = card["account_id"]
    to_account = _get_account_by_number(payload.to_account_number)
    to_account_id = to_account["account_id"]

    if to_account_id == from_account_id:
        raise HTTPException(status_code=400, detail="Cannot pay yourself with your own card's linked account")
    if to_account.get("status") != "active":
        raise HTTPException(status_code=400, detail="The recipient's account isn't active")

    # Same atomic three-way transaction transfers-service uses: debit the
    # card's account, credit the recipient's account, write one ledger
    # row, all-or-nothing. This is the actual fix - the previous version
    # of this endpoint only ever debited the sender via adjust_balance()
    # with no matching credit anywhere, so the money vanished instead of
    # reaching the recipient.
    payment_id = str(uuid.uuid4())
    client = dynamodb_client()
    accounts_table_name = raw_table_name("accounts")
    payments_table_name = raw_table_name("virtual-card-payments")

    payment_item = {
        "id": payment_id,
        "card_id": card["id"],
        "from_account_id": from_account_id,
        "to_account_id": to_account_id,
        "from_user_id": card["user_id"],
        "to_user_id": to_account["user_id"],
        "amount": payload.amount,
        "merchant_name": payload.merchant_name or "",
        "status": "completed",
        "created_at": now_iso(),
    }

    try:
        client.transact_write_items(
            TransactItems=[
                {
                    "Update": {
                        "TableName": accounts_table_name,
                        "Key": to_ddb_item({"account_id": from_account_id}),
                        "UpdateExpression": "SET balance = balance - :amt",
                        "ConditionExpression": (
                            "attribute_exists(account_id) AND record_type = :acct "
                            "AND #st = :active AND balance >= :amt"
                        ),
                        "ExpressionAttributeNames": {"#st": "status"},
                        "ExpressionAttributeValues": to_ddb_item(
                            {":amt": payload.amount, ":acct": "account", ":active": "active"}
                        ),
                    }
                },
                {
                    "Update": {
                        "TableName": accounts_table_name,
                        "Key": to_ddb_item({"account_id": to_account_id}),
                        "UpdateExpression": "SET balance = balance + :amt",
                        "ConditionExpression": (
                            "attribute_exists(account_id) AND record_type = :acct AND #st = :active"
                        ),
                        "ExpressionAttributeNames": {"#st": "status"},
                        "ExpressionAttributeValues": to_ddb_item(
                            {":amt": payload.amount, ":acct": "account", ":active": "active"}
                        ),
                    }
                },
                {
                    "Put": {
                        "TableName": payments_table_name,
                        "Item": to_ddb_item(payment_item),
                        "ConditionExpression": "attribute_not_exists(id)",
                    }
                },
            ]
        )
    except client.exceptions.TransactionCanceledException as exc:
        reasons = exc.response.get("CancellationReasons", [])
        if reasons and reasons[0].get("Code") == "ConditionalCheckFailed":
            raise HTTPException(status_code=402, detail="Insufficient funds on this card's linked account")
        raise HTTPException(status_code=409, detail="Payment could not be completed - accounts changed, try again")

    if card["mode"] == "single_use":
        tbl.update_item(
            Key={"id": card["id"]},
            UpdateExpression="SET used = :t, #s = :s",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={":t": True, ":s": "used"},
        )

    write_audit_log(card["user_id"], "virtual_card_payment", {
        "card_id": card["id"], "amount": str(payload.amount), "to_account_id": to_account_id,
    })

    # Notify BOTH sides - sender's debit, recipient's credit - same as a
    # regular transfer. Best-effort: the money has already moved by now.
    try:
        sns_publish(
            SNS_TOPIC_ENV,
            subject=f"₹{payload.amount} paid with virtual card {card['card_number_masked']}",
            message={
                "type": "virtual_card_payment",
                "user_id": card["user_id"],
                "summary": f"₹{payload.amount} paid with card ending {card['card_number'][-4:]}" + (f" at {payload.merchant_name}" if payload.merchant_name else ""),
                "card_id": card["id"], "amount": str(payload.amount),
            },
        )
        sns_publish(
            SNS_TOPIC_ENV,
            subject=f"₹{payload.amount} received",
            message={
                "type": "virtual_card_payment_received",
                "user_id": to_account["user_id"],
                "summary": f"₹{payload.amount} received from a virtual card payment",
                "card_id": card["id"], "amount": str(payload.amount),
            },
        )
    except Exception as exc:  # noqa: BLE001
        print(f"[virtual-cards] failed to publish notification: {exc}")

    return {
        "status": "paid",
        "amount": str(payload.amount),
        "card_number_masked": card["card_number_masked"],
        "to_account_number": payload.to_account_number,
        "merchant_name": payload.merchant_name,
        "card_status": "used" if card["mode"] == "single_use" else card["status"],
        "paid_at": payment_item["created_at"],
    }


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
