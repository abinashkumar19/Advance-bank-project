"""Admin analytics - bank-wide aggregated dashboards for staff (total
users, total balance, loan/FD/card counts, daily transfer volume). Reads
straight from each service's own DynamoDB table via Scan - fine for a
dev-sized dataset; a production version would read from a proper
warehouse/reporting store instead of live-scanning OLTP tables.

Deliberately a separate service from `admin` (which is user/account
management - freeze accounts, view KYC status, etc.) since staff
dashboards and staff account-management actions are different concerns
with different read patterns."""
import os
import sys
from collections import Counter
from decimal import Decimal

from fastapi import APIRouter, FastAPI

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from common.aws_clients import table

app = FastAPI(title="VeeraBank Admin Analytics Service", version="1.0.0")
router = APIRouter(prefix="/admin-analytics")


def _scan_all(tbl) -> list:
    items = []
    resp = tbl.scan()
    items.extend(resp.get("Items", []))
    while "LastEvaluatedKey" in resp:
        resp = tbl.scan(ExclusiveStartKey=resp["LastEvaluatedKey"])
        items.extend(resp.get("Items", []))
    return items


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@router.get("/")
def root():
    return {"service": "admin-analytics-service", "status": "running"}


@router.get("/summary")
def summary():
    users = _scan_all(table("users"))
    accounts = [a for a in _scan_all(table("accounts")) if a.get("record_type") == "account"]
    transfers = _scan_all(table("transfers"))
    loans = _scan_all(table("loans"))
    cards = _scan_all(table("cards"))
    fixed_deposits = _scan_all(table("fixed-deposits"))
    disputes = _scan_all(table("disputes"))
    support_tickets = _scan_all(table("support-tickets"))

    total_balance = sum((Decimal(str(a.get("balance", 0))) for a in accounts), Decimal("0"))
    total_transfer_volume = sum((Decimal(str(t.get("amount", 0))) for t in transfers), Decimal("0"))

    return {
        "users": {"total": len(users)},
        "accounts": {"total": len(accounts), "total_balance": str(total_balance)},
        "transfers": {"total": len(transfers), "total_volume": str(total_transfer_volume)},
        "loans": {"total": len(loans), "by_status": dict(Counter(l.get("status", "unknown") for l in loans))},
        "cards": {"total": len(cards), "by_type": dict(Counter(c.get("card_type", "unknown") for c in cards))},
        "fixed_deposits": {"total": len(fixed_deposits)},
        "disputes": {"total": len(disputes), "by_status": dict(Counter(d.get("status", "unknown") for d in disputes))},
        "support_tickets": {"total": len(support_tickets), "by_status": dict(Counter(t.get("status", "unknown") for t in support_tickets))},
    }


@router.get("/top-accounts")
def top_accounts(limit: int = 10):
    accounts = [a for a in _scan_all(table("accounts")) if a.get("record_type") == "account"]
    ranked = sorted(accounts, key=lambda a: Decimal(str(a.get("balance", 0))), reverse=True)[:limit]
    return [{"account_id": a["account_id"], "user_id": a.get("user_id"), "balance": str(a.get("balance", 0))} for a in ranked]


app.include_router(router)
