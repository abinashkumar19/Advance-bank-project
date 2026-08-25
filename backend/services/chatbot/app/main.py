"""Chatbot microservice - Cloud Bank's support assistant, powered by a
self-hosted model running entirely inside this cluster (Ollama, see
k8s/services/ollama-deployment.yaml) - NOT a third-party API. No API key,
no external network call, no per-message cost: every request stays inside
the VPC, cluster-internal DNS only (ollama-svc.veerabank.svc.cluster.local).

Like the earlier versions of this service, it's stateless - no DynamoDB
table, no server-side session. The frontend sends recent chat text history
with every request (see frontend/src/js/chatbot.js), and the CALLING
USER'S user_id comes from the logged-in session, never from chat text.
That user_id is the only thing that determines which account gets
debited - the model is never trusted to supply or invent a "from"
account, only a recipient account number and an amount. See send_money()
below.

Tradeoff worth knowing: a small (3B-class) CPU-hosted model is nowhere
near as reliable at multi-step tool-calling as a hosted frontier model -
it can occasionally skip a verification step, misread an amount, or
answer in an unexpected format. The prompt and parsing below are written
defensively for that reason (never trust the model's word alone - the
account lookups and transfer itself are re-verified independently every
time, see _run_tool). Swap OLLAMA_MODEL to something larger for better
reliability if you add more compute (see the deployment's comments).
"""
import json
import os
from decimal import Decimal
from typing import List, Literal, Optional

import requests
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

app = FastAPI(title="Cloud Bank Chatbot Service", version="3.0.0")

OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://ollama-svc.veerabank.svc.cluster.local:11434")
OLLAMA_MODEL = os.environ.get("OLLAMA_MODEL", "qwen2.5:3b-instruct")

ACCOUNTS_SERVICE_URL = os.environ.get("ACCOUNTS_SERVICE_URL", "http://accounts-svc.veerabank.svc.cluster.local")
TRANSFERS_SERVICE_URL = os.environ.get("TRANSFERS_SERVICE_URL", "http://transfers-svc.veerabank.svc.cluster.local")

SYSTEM_PROMPT = (
    "You are the Cloud Bank assistant, embedded in the Cloud Bank web app. "
    "You help customers understand their accounts, cards, transfers, statements, loans, "
    "cheques, and other Cloud Bank services, how to use the app, and you can also send money "
    "on their behalf using the verify_recipient_account and send_money tools.\n\n"
    "MONEY TRANSFER FLOW - follow this exactly, in order, one step at a time:\n"
    "1. Only start this flow if the user clearly says they want to send/transfer money.\n"
    "2. Ask for the recipient's account number if they haven't given one yet.\n"
    "3. The MOMENT you have an account number, call verify_recipient_account with it - "
    "do not ask the user to confirm first, just verify it immediately.\n"
    "4. If it's invalid, tell the user plainly and ask them to double check the number.\n"
    "5. If it's valid, tell the user whose account it is (the owner name the tool returned) "
    "so they can confirm it's who they meant, then ask how much to send.\n"
    "6. The MOMENT you have a numeric amount, call send_money with the account number and "
    "amount - do not ask for a second confirmation, the owner-name check in step 5 IS the "
    "confirmation step.\n"
    "7. Report the tool's result plainly - success with the amount and recipient, or the "
    "exact reason it failed (insufficient funds, account frozen, etc).\n\n"
    "Never invent account numbers, balances, owner names, or transaction outcomes - only "
    "state facts a tool actually returned. You cannot see the user's balance or transaction "
    "history directly; if asked, point them to the Accounts or Transactions page instead. "
    "Keep replies short and friendly. If asked something outside banking/the app, gently "
    "redirect back to how you can help with Cloud Bank."
)

# Ollama's /api/chat tool schema is the same shape OpenAI popularized:
# {type: "function", function: {name, description, parameters}}.
TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "verify_recipient_account",
            "description": "Look up a Cloud Bank account by its account number and confirm it exists before sending money to it. Always call this the moment the user provides an account number for a transfer.",
            "parameters": {
                "type": "object",
                "properties": {
                    "account_number": {"type": "string", "description": "The recipient's Cloud Bank account number, digits only"}
                },
                "required": ["account_number"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "send_money",
            "description": "Send money from the current user's own account to a recipient's account by account number. The sender's account is always the current logged-in user - never ask for or accept a 'from' account number.",
            "parameters": {
                "type": "object",
                "properties": {
                    "account_number": {"type": "string", "description": "The recipient's Cloud Bank account number, digits only"},
                    "amount": {"type": "number", "description": "Amount to send, in the account's currency, greater than zero"},
                },
                "required": ["account_number", "amount"],
            },
        },
    },
]


class ChatMessage(BaseModel):
    role: Literal["user", "assistant"]
    content: str


class ChatRequest(BaseModel):
    message: str
    history: List[ChatMessage] = Field(default_factory=list, description="Recent turns, oldest first")
    user_id: str = Field(..., description="The logged-in user's user_id - determines which account can be debited, never taken from chat text")


class ChatResponse(BaseModel):
    reply: str


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.get("/chatbot/")
def root():
    try:
        resp = requests.get(f"{OLLAMA_URL}/", timeout=3)
        ollama_up = resp.ok
    except requests.RequestException:
        ollama_up = False
    return {"service": "chatbot-service", "status": "running", "model": OLLAMA_MODEL, "ollama_reachable": ollama_up}


def _get_account_by_number(account_number: str) -> Optional[dict]:
    try:
        resp = requests.get(f"{ACCOUNTS_SERVICE_URL}/accounts/by-number/{account_number}", timeout=8)
        if resp.status_code == 404:
            return None
        resp.raise_for_status()
        return resp.json()
    except requests.RequestException:
        return None


def _get_account_by_user(user_id: str) -> Optional[dict]:
    try:
        resp = requests.get(f"{ACCOUNTS_SERVICE_URL}/accounts/by-user/{user_id}", timeout=8)
        if resp.status_code == 404:
            return None
        resp.raise_for_status()
        return resp.json()
    except requests.RequestException:
        return None


def _run_tool(tool_name: str, tool_input: dict, requesting_user_id: str) -> dict:
    if tool_name == "verify_recipient_account":
        account = _get_account_by_number(str(tool_input.get("account_number", "")).strip())
        if not account:
            return {"valid": False}
        return {
            "valid": True,
            "owner_name": account["owner_name"],
            "account_type": account["account_type"],
            "status": account.get("status", "active"),
        }

    if tool_name == "send_money":
        # The sender's account comes ONLY from the authenticated user_id on
        # this request - never from tool_input, which the model produced
        # and (especially with a small self-hosted model) shouldn't be
        # fully trusted to always follow instructions correctly.
        sender = _get_account_by_user(requesting_user_id)
        if not sender:
            return {"success": False, "error": "You don't have a Cloud Bank account to send money from yet."}

        recipient = _get_account_by_number(str(tool_input.get("account_number", "")).strip())
        if not recipient:
            return {"success": False, "error": "That account number doesn't exist. Ask the user to double check it."}
        if recipient["account_id"] == sender["account_id"]:
            return {"success": False, "error": "That's the user's own account - can't send money to themselves."}

        try:
            amount = Decimal(str(tool_input.get("amount", "0")))
        except Exception:  # noqa: BLE001
            return {"success": False, "error": "Invalid amount."}
        if amount <= 0:
            return {"success": False, "error": "Amount must be greater than zero."}

        try:
            resp = requests.post(
                f"{TRANSFERS_SERVICE_URL}/transfers/",
                json={
                    "from_account_id": sender["account_id"],
                    "to_account_id": recipient["account_id"],
                    "amount": str(amount),
                    "user_id": requesting_user_id,
                    "sender_name": sender["owner_name"],
                    "note": "Sent via Cloud Bank chat assistant",
                },
                timeout=15,
            )
            if resp.status_code == 402:
                return {"success": False, "error": "Insufficient funds."}
            resp.raise_for_status()
            data = resp.json()
            return {
                "success": True,
                "amount": str(amount),
                "recipient_name": recipient["owner_name"],
                "transfer_id": data.get("id"),
            }
        except requests.RequestException as exc:
            return {"success": False, "error": f"The transfer service is temporarily unavailable: {exc}"}

    return {"error": f"Unknown tool {tool_name}"}


def _call_ollama(messages: list) -> dict:
    resp = requests.post(
        f"{OLLAMA_URL}/api/chat",
        json={
            "model": OLLAMA_MODEL,
            "messages": messages,
            "tools": TOOLS,
            "stream": False,
            "options": {"temperature": 0.3},
        },
        timeout=90,  # CPU inference on a small model can genuinely take this long, especially cold
    )
    resp.raise_for_status()
    return resp.json()


def _parse_tool_arguments(raw_args) -> dict:
    """Ollama usually returns tool_calls[].function.arguments as a dict
    already, but some model/version combos return a JSON string instead -
    handle both rather than assuming."""
    if isinstance(raw_args, dict):
        return raw_args
    try:
        return json.loads(raw_args)
    except (TypeError, json.JSONDecodeError):
        return {}


@app.post("/chatbot/message", response_model=ChatResponse)
def send_message(req: ChatRequest):
    if not req.message.strip():
        raise HTTPException(status_code=400, detail="Message can't be empty.")

    messages = [{"role": "system", "content": SYSTEM_PROMPT}]
    # Cap history so a long-running chat session doesn't blow up the
    # context window a small local model has to work with.
    for turn in req.history[-12:]:
        messages.append({"role": turn.role, "content": turn.content})
    messages.append({"role": "user", "content": req.message})

    try:
        # Tool-use loop: the model may need one or more round trips
        # (verify, then send) before it has a final plain-text reply.
        # Each tool call is executed here, server-side, and fed back in -
        # the frontend only ever sees the final text at the end of this
        # loop.
        for _ in range(5):  # hard cap so a stuck loop can't hang the request forever
            data = _call_ollama(messages)
            message = data.get("message", {})
            tool_calls = message.get("tool_calls") or []

            if not tool_calls:
                reply = (message.get("content") or "").strip()
                return {"reply": reply or "Sorry, I didn't catch that - could you rephrase?"}

            messages.append(message)
            for call in tool_calls:
                fn = call.get("function", {})
                name = fn.get("name", "")
                args = _parse_tool_arguments(fn.get("arguments", {}))
                result = _run_tool(name, args, req.user_id)
                messages.append({"role": "tool", "name": name, "content": json.dumps(result)})

        return {"reply": "Sorry, that's taking longer than expected - please try again."}

    except requests.HTTPError as e:
        detail = e.response.text[:300] if e.response is not None else str(e)
        raise HTTPException(status_code=502, detail=f"Model server error: {detail}")
    except requests.RequestException:
        raise HTTPException(status_code=503, detail="The chatbot's model server isn't reachable right now.")
    except Exception as e:  # noqa: BLE001
        raise HTTPException(status_code=502, detail=f"Chatbot is temporarily unavailable: {e}")
