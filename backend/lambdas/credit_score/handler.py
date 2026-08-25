"""
credit-score Lambda
--------------------
Computes a CIBIL-style credit score (300-900) for a VeeraBank user, the
same range and shape used by India's real credit bureaus. Invoked two ways:

  1. Directly by the loans-service (via API Gateway route POST /score) when
     a user opens the "Check my score" screen.
  2. As the first step of the loan-approval Step Functions state machine
     (see modules/scoring/state_machine.asl.json) - the workflow branches
     on the score this function returns before a loan is approved/rejected.

The algorithm is intentionally simple and fully explainable (every factor
and its point contribution is returned alongside the score) rather than a
black-box model - a real bank has to be able to tell a customer *why* they
got the score they did.
"""
import json
import os
from datetime import datetime, timezone
from decimal import Decimal

import boto3
from boto3.dynamodb.conditions import Key

dynamodb = boto3.resource("dynamodb", region_name=os.getenv("AWS_REGION", "us-east-1"))
ACCOUNTS_TABLE = os.environ["ACCOUNTS_TABLE"]
TRANSFERS_TABLE = os.environ["TRANSFERS_TABLE"]
LOANS_TABLE = os.environ["LOANS_TABLE"]

accounts_table = dynamodb.Table(ACCOUNTS_TABLE)
transfers_table = dynamodb.Table(TRANSFERS_TABLE)
loans_table = dynamodb.Table(LOANS_TABLE)

BASE_SCORE = 300
MAX_SCORE = 900


def _decimal_to_float(obj):
    if isinstance(obj, Decimal):
        return float(obj)
    raise TypeError


def _account_age_factor(accounts):
    """Older relationships with the bank are lower-risk. Up to 120 points."""
    if not accounts:
        return 0, "No open accounts on file"

    oldest = min(
        datetime.fromisoformat(a["created_at"]) for a in accounts if a.get("created_at")
    )
    months = max(0, (datetime.now(timezone.utc) - oldest).days // 30)
    points = min(120, months * 4)
    return points, f"Account relationship of {months} month(s)"


def _balance_factor(accounts):
    """Healthy average balance signals financial stability. Up to 150 points."""
    balances = [float(a.get("balance", 0)) for a in accounts]
    avg_balance = sum(balances) / len(balances) if balances else 0

    if avg_balance >= 500000:
        points = 150
    elif avg_balance >= 100000:
        points = 110
    elif avg_balance >= 25000:
        points = 70
    elif avg_balance >= 5000:
        points = 35
    else:
        points = 10

    return points, f"Average balance of ₹{avg_balance:,.0f}"


def _repayment_history_factor(loans):
    """On-time EMI history is the single heaviest-weighted real-world CIBIL
    factor (~35%). Up to 250 points here."""
    if not loans:
        return 150, "No existing loan history (neutral)"

    on_time = sum(1 for l in loans if l.get("status") in ("active", "closed") and not l.get("missed_payments"))
    missed = sum(int(l.get("missed_payments", 0)) for l in loans)

    ratio = on_time / len(loans) if loans else 1
    points = round(ratio * 250) - min(missed * 25, 150)
    points = max(0, points)

    detail = f"{on_time}/{len(loans)} loans in good standing"
    if missed:
        detail += f", {missed} missed payment(s)"
    return points, detail


def _transaction_consistency_factor(transfers):
    """Regular, non-erratic transaction activity. Up to 100 points."""
    count = len(transfers)
    if count == 0:
        return 20, "No transaction history yet"
    if count >= 50:
        points = 100
    elif count >= 20:
        points = 70
    elif count >= 5:
        points = 40
    else:
        points = 20
    return points, f"{count} transfers on record"


def _credit_utilization_factor(accounts, loans):
    """Lower outstanding-debt-to-balance ratio is better. Up to 130 points."""
    total_balance = sum(float(a.get("balance", 0)) for a in accounts) or 1
    total_outstanding = sum(float(l.get("outstanding_amount", 0)) for l in loans)
    utilization = min(1.0, total_outstanding / total_balance)

    points = round((1 - utilization) * 130)
    return points, f"{utilization*100:.0f}% credit utilization"


def compute_score(user_id: str) -> dict:
    accounts = accounts_table.query(
        IndexName="user_id-index",
        KeyConditionExpression=Key("user_id").eq(user_id),
    ).get("Items", [])

    account_ids = [a["account_id"] for a in accounts]
    transfers = []
    for aid in account_ids:
        transfers += transfers_table.query(
            IndexName="from_account_id-index",
            KeyConditionExpression=Key("from_account_id").eq(aid),
        ).get("Items", [])

    loans = loans_table.query(
        IndexName="user_id-index",
        KeyConditionExpression=Key("user_id").eq(user_id),
    ).get("Items", [])

    factors = []
    total_points = 0
    for factor_fn, args in [
        (_account_age_factor, (accounts,)),
        (_balance_factor, (accounts,)),
        (_repayment_history_factor, (loans,)),
        (_transaction_consistency_factor, (transfers,)),
        (_credit_utilization_factor, (accounts, loans)),
    ]:
        points, detail = factor_fn(*args)
        total_points += points
        factors.append({"factor": factor_fn.__name__.strip("_"), "points": points, "detail": detail})

    score = min(MAX_SCORE, BASE_SCORE + total_points)

    if score >= 750:
        band = "Excellent"
    elif score >= 700:
        band = "Good"
    elif score >= 650:
        band = "Fair"
    elif score >= 550:
        band = "Poor"
    else:
        band = "Very Poor"

    return {
        "user_id": user_id,
        "score": score,
        "band": band,
        "max_score": MAX_SCORE,
        "min_score": BASE_SCORE,
        "factors": factors,
        "computed_at": datetime.now(timezone.utc).isoformat(),
    }


def handler(event, context):
    # Supports both direct Step Functions invocation ({"user_id": "..."})
    # and API Gateway HTTP proxy invocation (body is a JSON string).
    if "body" in event:
        body = json.loads(event.get("body") or "{}")
        user_id = body.get("user_id")
    else:
        user_id = event.get("user_id")

    if not user_id:
        return {"statusCode": 400, "body": json.dumps({"error": "user_id is required"})}

    result = compute_score(user_id)

    if "body" in event:
        return {
            "statusCode": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps(result, default=_decimal_to_float),
        }
    return json.loads(json.dumps(result, default=_decimal_to_float))
