"""Insurance - browse a policy catalog, purchase a policy (debits the
first premium immediately), track owned policies. Structured the same
way loans/fixed-deposits are: a small static catalog + a per-purchase
record in DynamoDB, not a real underwriting integration."""
import os
import sys
from datetime import date, timedelta
from decimal import Decimal
from typing import List

from fastapi import APIRouter, FastAPI, HTTPException
from pydantic import BaseModel

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from common.aws_clients import sns_publish, table
from common.service_base import adjust_balance, get_account_or_404, new_id, now_iso, write_audit_log

SNS_TOPIC_ENV = "USER_REGISTERED_TOPIC_ARN"

app = FastAPI(title="VeeraBank Insurance Service", version="1.0.0")
router = APIRouter(prefix="/insurance")
tbl = table("insurance")

# Static demo catalog - real coverage amounts/premiums would come from an
# underwriting/pricing engine, not a hardcoded dict.
CATALOG = [
    {"plan_id": "term-life-50l", "name": "Term Life - ₹50L cover", "category": "life", "coverage": "5000000", "annual_premium": "8500"},
    {"plan_id": "term-life-1cr", "name": "Term Life - ₹1Cr cover", "category": "life", "coverage": "10000000", "annual_premium": "15500"},
    {"plan_id": "health-family-10l", "name": "Family Health - ₹10L cover", "category": "health", "coverage": "1000000", "annual_premium": "18000"},
    {"plan_id": "health-individual-5l", "name": "Individual Health - ₹5L cover", "category": "health", "coverage": "500000", "annual_premium": "7200"},
    {"plan_id": "vehicle-comprehensive", "name": "Vehicle Comprehensive", "category": "vehicle", "coverage": "800000", "annual_premium": "12000"},
    {"plan_id": "home-standard", "name": "Home Insurance - Standard", "category": "home", "coverage": "3000000", "annual_premium": "5500"},
]
CATALOG_BY_ID = {p["plan_id"]: p for p in CATALOG}


class PurchaseRequest(BaseModel):
    user_id: str
    account_id: str
    plan_id: str


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@router.get("/")
def root():
    return {"service": "insurance-service", "status": "running"}


@router.get("/catalog")
def catalog():
    return CATALOG


@router.post("/purchase", status_code=201)
def purchase(payload: PurchaseRequest):
    plan = CATALOG_BY_ID.get(payload.plan_id)
    if not plan:
        raise HTTPException(status_code=404, detail="Unknown plan_id")
    account = get_account_or_404(payload.account_id)
    if account["user_id"] != payload.user_id:
        raise HTTPException(status_code=403, detail="You can only purchase using your own account")

    premium = Decimal(plan["annual_premium"])
    adjust_balance(payload.account_id, -premium)  # raises 402 if insufficient funds

    item = {
        "id": new_id(),
        "user_id": payload.user_id,
        "account_id": payload.account_id,
        "plan_id": plan["plan_id"],
        "plan_name": plan["name"],
        "category": plan["category"],
        "coverage": plan["coverage"],
        "annual_premium": plan["annual_premium"],
        "policy_number": f"POL{new_id()[:8].upper()}",
        "status": "active",
        "purchased_at": now_iso(),
        "renewal_date": (date.today() + timedelta(days=365)).isoformat(),
        "created_at": now_iso(),
    }
    tbl.put_item(Item=item)
    write_audit_log(payload.user_id, "insurance_purchased", {"policy_id": item["id"], "plan": plan["name"]})

    try:
        sns_publish(
            SNS_TOPIC_ENV,
            subject=f"{plan['name']} policy purchased",
            message={
                "type": "insurance_purchased",
                "user_id": payload.user_id,
                "summary": f"₹{premium} debited - {plan['name']} policy is now active",
                "policy_id": item["id"],
                "amount": str(premium),
            },
        )
    except Exception as exc:  # noqa: BLE001
        print(f"[insurance] failed to publish notification: {exc}")

    return item


@router.get("/user/{user_id}", response_model=List[dict])
def list_for_user(user_id: str):
    resp = tbl.query(IndexName="user_id-index", KeyConditionExpression="user_id = :u", ExpressionAttributeValues={":u": user_id})
    return sorted(resp.get("Items", []), key=lambda i: i.get("created_at", ""), reverse=True)


@router.get("/{policy_id}")
def get_policy(policy_id: str):
    resp = tbl.get_item(Key={"id": policy_id})
    item = resp.get("Item")
    if not item:
        raise HTTPException(status_code=404, detail="Policy not found")
    return item


@router.patch("/{policy_id}/cancel")
def cancel(policy_id: str):
    resp = tbl.get_item(Key={"id": policy_id})
    item = resp.get("Item")
    if not item:
        raise HTTPException(status_code=404, detail="Policy not found")
    if item["status"] != "active":
        raise HTTPException(status_code=400, detail=f"Policy is already {item['status']}")
    tbl.update_item(Key={"id": policy_id}, UpdateExpression="SET #s = :s", ExpressionAttributeNames={"#s": "status"}, ExpressionAttributeValues={":s": "cancelled"})
    write_audit_log(item["user_id"], "insurance_cancelled", {"policy_id": policy_id})
    return {**item, "status": "cancelled"}


app.include_router(router)
