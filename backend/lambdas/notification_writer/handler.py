"""
notification-writer Lambda
---------------------------
The subscriber behind SNS -> SQS (user-registered-notifications queue) for
every notification event VeeraBank's services publish - despite the queue's
"user-registered" name (kept for backwards compat, see the SNS_TOPIC_ENV
comment in each service), it's a general-purpose notifications topic now:
users-service (signup), transfers-service (debit/credit), and
cards-service (card issued) all publish to it.

For every message this Lambda:
  1. Writes a row into the same DynamoDB table the notifications-service
     microservice already reads from (GET /notifications/user/{id}), so it
     shows up in-app with no extra plumbing.
  2. Forwards it to Telegram, so the user (well - the account owner
     watching the bot, in a dev/demo single-tenant setup like this one)
     gets a push notification for every debit, credit, card creation, or
     signup, in addition to the in-app feed.
  3. If SES_SENDER_EMAIL is set and the event is a signup, additionally
     sends a welcome email via SES (unchanged from before).
"""
import json
import os
import urllib.request
import urllib.error
import uuid
from datetime import datetime, timezone

import boto3

dynamodb = boto3.resource("dynamodb", region_name=os.getenv("AWS_REGION", "us-east-1"))
TABLE_NAME = os.environ["NOTIFICATIONS_TABLE"]
table = dynamodb.Table(TABLE_NAME)

ses = boto3.client("ses", region_name=os.getenv("AWS_REGION", "us-east-1"))
SENDER_EMAIL = os.getenv("SES_SENDER_EMAIL", "")

secretsmanager = boto3.client("secretsmanager", region_name=os.getenv("AWS_REGION", "us-east-1"))
TELEGRAM_SECRET_NAME = os.getenv("TELEGRAM_SECRET_NAME", "")

# Module-level cache: Lambda execution environments are reused across
# invocations, so this avoids a Secrets Manager call on every single
# notification. `False` (not None) marks "looked up, and it's not
# configured" so a missing secret doesn't get retried on every message.
_telegram_creds_cache = None


def _get_telegram_creds():
    global _telegram_creds_cache
    if _telegram_creds_cache is not None:
        return _telegram_creds_cache or None

    if not TELEGRAM_SECRET_NAME:
        print("[notification-writer] TELEGRAM_SECRET_NAME not set, skipping Telegram")
        _telegram_creds_cache = False
        return None

    try:
        resp = secretsmanager.get_secret_value(SecretId=TELEGRAM_SECRET_NAME)
        creds = json.loads(resp["SecretString"])
        bot_token = creds.get("bot_token")
        chat_id = creds.get("chat_id")
        if not bot_token or not chat_id:
            print("[notification-writer] Telegram secret exists but is missing bot_token/chat_id")
            _telegram_creds_cache = False
            return None
        _telegram_creds_cache = {"bot_token": bot_token, "chat_id": chat_id}
        return _telegram_creds_cache
    except Exception as exc:  # noqa: BLE001 - Telegram is best-effort, never raise
        print(f"[notification-writer] failed to read Telegram secret: {exc}")
        _telegram_creds_cache = False
        return None


# One emoji per event type, purely cosmetic, falls back to a bell.
_TELEGRAM_ICONS = {
    "user_registered": "🆕",
    "transfer_debit": "➖",
    "transfer_credit": "➕",
    "card_created": "💳",
}


def _send_telegram(notif_type: str, subject: str, message: str):
    creds = _get_telegram_creds()
    if not creds:
        return

    icon = _TELEGRAM_ICONS.get(notif_type, "🔔")
    text = f"{icon} <b>{subject}</b>\n{message}"

    url = f"https://api.telegram.org/bot{creds['bot_token']}/sendMessage"
    body = json.dumps({"chat_id": creds["chat_id"], "text": text, "parse_mode": "HTML"}).encode("utf-8")
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            resp.read()
    except urllib.error.URLError as exc:  # noqa: BLE001 - never let a Telegram hiccup fail the batch
        print(f"[notification-writer] Telegram send failed: {exc}")


def _send_welcome_email(payload: dict):
    to_email = payload.get("email")
    if not SENDER_EMAIL or not to_email:
        if not SENDER_EMAIL:
            print("[notification-writer] SES_SENDER_EMAIL not set, skipping welcome email")
        return

    full_name = payload.get("full_name", "there")
    try:
        ses.send_email(
            Source=SENDER_EMAIL,
            Destination={"ToAddresses": [to_email]},
            Message={
                "Subject": {"Data": "Welcome to VeeraBank!"},
                "Body": {
                    "Text": {
                        "Data": (
                            f"Hi {full_name},\n\n"
                            "Your VeeraBank account has been created successfully. "
                            "Welcome aboard!\n\nVeeraBank"
                        )
                    }
                },
            },
        )
    except Exception as exc:  # noqa: BLE001 - don't fail the whole batch over one email
        print(f"[notification-writer] SES send_email failed: {exc}")


def handler(event, context):
    for record in event.get("Records", []):
        # SQS record body is the raw SNS message envelope (JSON string).
        sqs_body = json.loads(record["body"])
        raw_message = sqs_body.get("Message", sqs_body.get("body", ""))
        subject = sqs_body.get("Subject", "Notification")

        # Every publisher (users/transfers/cards-service) sends the SNS
        # Message as a JSON string with a "type" field; fall back to plain
        # text + "user_registered" for anything else / older messages.
        try:
            payload = json.loads(raw_message)
            display_message = payload.get("summary", raw_message)
        except (json.JSONDecodeError, TypeError):
            payload = {}
            display_message = raw_message

        notif_type = payload.get("type", "user_registered")

        item = {
            "id": str(uuid.uuid4()),
            "user_id": payload.get("user_id", "unknown"),
            "type": notif_type,
            "subject": subject,
            "message": display_message,
            "read": False,
            "created_at": datetime.now(timezone.utc).isoformat(),
        }
        table.put_item(Item=item)

        # Every notification, of every type, also goes to Telegram.
        _send_telegram(notif_type, subject, display_message)

        if notif_type == "user_registered":
            _send_welcome_email(payload)

    return {"statusCode": 200}
