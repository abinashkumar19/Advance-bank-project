"""
fraud-score Lambda
-------------------
Rules-based, fully explainable fraud risk scoring (0-100, higher = riskier)
for a single transaction. Consumes the fraud-check SQS queue (see
modules/messaging) that EventBridge routes every TransactionCompleted event
into, so it never sits in the hot path of an actual payment.

Each rule is independent, named, and its point contribution is recorded -
this is deliberately NOT a black-box ML model. A real fraud team needs to
see exactly why a transaction was flagged, and a false positive needs to be
explainable to the customer on a support call.

Writes the result into the fraud-detection generic DynamoDB table (already
served by the fraud-detection microservice's existing GET endpoints).
"""
import json
import os
from datetime import datetime, timezone
from decimal import Decimal

import boto3
from boto3.dynamodb.conditions import Key

dynamodb = boto3.resource("dynamodb", region_name=os.getenv("AWS_REGION", "us-east-1"))
FRAUD_TABLE = os.environ["FRAUD_TABLE"]
TRANSFERS_TABLE = os.environ["TRANSFERS_TABLE"]

fraud_table = dynamodb.Table(FRAUD_TABLE)
transfers_table = dynamodb.Table(TRANSFERS_TABLE)

HIGH_VALUE_THRESHOLD = 200000       # ₹2,00,000
VERY_HIGH_VALUE_THRESHOLD = 1000000  # ₹10,00,000
VELOCITY_WINDOW_MINUTES = 10
VELOCITY_COUNT_THRESHOLD = 4
ODD_HOUR_START, ODD_HOUR_END = 0, 5  # 12am-5am


def _rule_amount(txn):
    amount = float(txn.get("amount", 0))
    if amount >= VERY_HIGH_VALUE_THRESHOLD:
        return 35, f"Very high value transaction (₹{amount:,.0f})"
    if amount >= HIGH_VALUE_THRESHOLD:
        return 18, f"High value transaction (₹{amount:,.0f})"
    return 0, None


def _rule_odd_hour(txn):
    ts = txn.get("created_at")
    if not ts:
        return 0, None
    hour = datetime.fromisoformat(ts).hour
    if ODD_HOUR_START <= hour <= ODD_HOUR_END:
        return 15, f"Transaction at {hour:02d}:00 (odd hour)"
    return 0, None


def _rule_velocity(txn):
    """Multiple transfers from the same account in a short window."""
    from_account = txn.get("from_account_id")
    if not from_account:
        return 0, None

    recent = transfers_table.query(
        IndexName="from_account_id-index",
        KeyConditionExpression=Key("from_account_id").eq(from_account),
    ).get("Items", [])

    now = datetime.now(timezone.utc)
    recent_count = 0
    for r in recent:
        ts = r.get("created_at")
        if not ts:
            continue
        age_minutes = (now - datetime.fromisoformat(ts)).total_seconds() / 60
        if age_minutes <= VELOCITY_WINDOW_MINUTES:
            recent_count += 1

    if recent_count >= VELOCITY_COUNT_THRESHOLD:
        return 30, f"{recent_count} transfers from this account in {VELOCITY_WINDOW_MINUTES} min"
    return 0, None


def _rule_new_beneficiary(txn):
    """First-ever transfer to this recipient, paired with a high amount, is
    a classic account-takeover pattern."""
    if not txn.get("is_new_beneficiary"):
        return 0, None
    amount = float(txn.get("amount", 0))
    if amount >= HIGH_VALUE_THRESHOLD:
        return 20, "High-value transfer to a first-time beneficiary"
    return 5, "Transfer to a first-time beneficiary"


def _rule_round_amount(txn):
    """Fraud rings frequently test with suspiciously round amounts."""
    amount = float(txn.get("amount", 0))
    if amount > 0 and amount % 50000 == 0 and amount >= 100000:
        return 8, f"Suspiciously round amount (₹{amount:,.0f})"
    return 0, None


def score_transaction(txn: dict) -> dict:
    rules = [_rule_amount, _rule_odd_hour, _rule_velocity, _rule_new_beneficiary, _rule_round_amount]

    triggered = []
    total = 0
    for rule in rules:
        points, reason = rule(txn)
        if points:
            total += points
            triggered.append({"rule": rule.__name__.strip("_"), "points": points, "reason": reason})

    risk_score = min(100, total)

    if risk_score >= 60:
        verdict = "block"
    elif risk_score >= 30:
        verdict = "review"
    else:
        verdict = "allow"

    return {
        "id": txn.get("id", txn.get("transaction_id", "unknown")),
        "user_id": txn.get("user_id", ""),
        "risk_score": risk_score,
        "verdict": verdict,
        "triggered_rules": triggered,
        "scored_at": datetime.now(timezone.utc).isoformat(),
    }


def handler(event, context):
    for record in event.get("Records", []):
        body = json.loads(record["body"])
        # EventBridge wraps the original transaction in a "detail" key.
        txn = body.get("detail", body)

        result = score_transaction(txn)
        fraud_table.put_item(Item=json.loads(json.dumps(result), parse_float=Decimal))

        if result["verdict"] != "allow":
            print(f"[fraud-score] {result['verdict'].upper()}: txn {result['id']} scored {result['risk_score']}")

    return {"statusCode": 200}
