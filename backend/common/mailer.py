"""Minimal SMTP mailer shared by any service that needs to send email
(currently just users-service, for OTP codes).

Credentials never live in the repo. They're set as GitHub Environment
secrets, injected into a k8s Secret named `app-secrets` by
.github/workflows/deploy.yml at deploy time, and mounted into the pod as
plain env vars - see k8s/services/users-deployment.yaml.

Only two secrets are required:
  SMTP_USER           the Gmail address that logs in to send, e.g. you@gmail.com
  SMTP_APP_PASSWORD   a Gmail app password (NOT your normal account password) -
                       Google Account -> Security -> 2-Step Verification -> App passwords

Everything else has a sane default and doesn't need to be set:
  SMTP_HOST           defaults to smtp.gmail.com
  SMTP_PORT           defaults to 587 (STARTTLS)
  SMTP_FROM_EMAIL     defaults to SMTP_USER
  SMTP_FROM_NAME      defaults to "Cloud Bank"

If SMTP_USER / SMTP_APP_PASSWORD are missing, send_email logs and no-ops
instead of raising, so services degrade gracefully in environments (like
local dev) where mail isn't configured.
"""
import os
import smtplib
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText


def _config():
    return {
        "host": os.getenv("SMTP_HOST", "smtp.gmail.com"),
        "port": int(os.getenv("SMTP_PORT", "587")),
        "user": os.getenv("SMTP_USER"),
        "app_password": os.getenv("SMTP_APP_PASSWORD"),
        "from_email": os.getenv("SMTP_FROM_EMAIL") or os.getenv("SMTP_USER"),
        "from_name": os.getenv("SMTP_FROM_NAME", "Cloud Bank"),
    }


def send_email(to_email: str, subject: str, body_text: str, body_html: str | None = None) -> bool:
    """Send a plain-text (optionally +HTML) email. Returns True if it was
    sent, False if mail isn't configured (see module docstring) or the
    send failed - callers should treat False as "log it and move on",
    not as a reason to fail the whole request."""
    cfg = _config()
    if not (cfg["user"] and cfg["app_password"]):
        print(f"[mailer] SMTP not configured, skipping email to {to_email}: {subject}")
        return False

    msg = MIMEMultipart("alternative")
    msg["Subject"] = subject
    msg["From"] = f'{cfg["from_name"]} <{cfg["from_email"]}>'
    msg["To"] = to_email
    msg.attach(MIMEText(body_text, "plain"))
    if body_html:
        msg.attach(MIMEText(body_html, "html"))

    try:
        with smtplib.SMTP(cfg["host"], cfg["port"], timeout=10) as server:
            server.starttls()
            server.login(cfg["user"], cfg["app_password"])
            server.sendmail(cfg["from_email"], [to_email], msg.as_string())
        return True
    except Exception as e:  # noqa: BLE001 - never let a mail failure 500 the request
        print(f"[mailer] failed to send to {to_email}: {e}")
        return False


def send_otp_email(to_email: str, code: str, purpose: str = "signup") -> bool:
    verb = "verify your email" if purpose == "signup" else "confirm this action"
    subject = f"Your Cloud Bank verification code: {code}"
    text = (
        f"Your Cloud Bank verification code is {code}.\n\n"
        f"Enter this code to {verb}. It expires in 5 minutes.\n\n"
        f"If you didn't request this, you can safely ignore this email."
    )

    # Table-based layout, inline styles only, no flexbox/grid/backdrop-filter -
    # matches the in-app OTP screen's look (individual digit boxes, violet/
    # green accent, dark card) using only what email clients (Outlook,
    # Gmail, Apple Mail) can actually render consistently.
    digit_cell = (
        '<td width="40" style="width:40px; height:52px; text-align:center; vertical-align:middle; '
        'background-color:#181229; border:1px solid #2c2447; border-radius:10px; '
        'font-family:\'Courier New\',monospace; font-size:24px; font-weight:700; color:#f6f5fc;">{d}</td>'
    )
    spacer_cell = '<td width="8"></td>'
    digit_cells = spacer_cell.join(digit_cell.format(d=d) for d in code)

    html = f"""
    <div style="background-color:#0a0713; padding:32px 16px; font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;">
      <table role="presentation" width="100%" style="max-width:420px; margin:0 auto; border-collapse:collapse;">
        <tr>
          <td style="background-color:#120d21; border:1px solid #241d3d; border-radius:20px; padding:36px 28px; text-align:center;">

            <table role="presentation" align="center" style="margin:0 auto 20px;">
              <tr>
                <td width="52" height="52" style="width:52px; height:52px; border-radius:14px; background-color:#8b7cff; text-align:center; vertical-align:middle; font-family:'Segoe UI',sans-serif; font-size:22px; font-weight:700; color:#050308;">C</td>
              </tr>
            </table>

            <div style="font-family:'Segoe UI',sans-serif; font-size:20px; font-weight:700; color:#f6f5fc; margin-bottom:6px;">
              Cloud<span style="color:#8b7cff;">Bank</span>
            </div>
            <p style="color:#a6a1c2; font-size:13px; margin:0 0 24px;">Your verification code</p>

            <table role="presentation" align="center" style="margin:0 auto 24px;">
              <tr>{digit_cells}</tr>
            </table>

            <p style="color:#a6a1c2; font-size:13px; line-height:1.6; margin:0 0 4px;">
              Enter this code to {verb}.
            </p>
            <p style="display:inline-block; background-color:#2b2417; color:#ffb648; font-size:11.5px; font-weight:700; letter-spacing:.4px; text-transform:uppercase; padding:5px 12px; border-radius:999px; margin:6px 0 20px;">
              Expires in 5 minutes
            </p>

            <div style="border-top:1px solid #241d3d; padding-top:16px; margin-top:4px;">
              <p style="color:#6d6890; font-size:11.5px; line-height:1.6; margin:0;">
                If you didn't request this, you can safely ignore this email - your account stays secure.
              </p>
            </div>

          </td>
        </tr>
      </table>
    </div>
    """
    return send_email(to_email, subject, text, html)


def send_transfer_sent_email(to_email: str, sender_name: str, recipient_name: str, amount, note: str | None = None) -> bool:
    """Sent to the person who just sent money - a receipt, basically."""
    subject = f"You sent ${amount} on Cloud Bank"
    note_line = f"\nNote: {note}" if note else ""
    text = (
        f"Hi {sender_name},\n\n"
        f"You sent ${amount} to {recipient_name}.{note_line}\n\n"
        f"If you didn't make this transfer, contact support right away."
    )
    html = f"""
      <div style="font-family:sans-serif; max-width:420px; margin:0 auto;">
        <h2 style="margin-bottom:4px;">Cloud Bank</h2>
        <p style="color:#333;">Hi {sender_name},</p>
        <p style="color:#333;">You sent <strong>${amount}</strong> to <strong>{recipient_name}</strong>.</p>
        {f'<p style="color:#555; font-size:13px;">Note: {note}</p>' if note else ''}
        <p style="color:#555; font-size:13px;">If you didn't make this transfer, contact support right away.</p>
      </div>
    """
    return send_email(to_email, subject, text, html)


def send_transfer_received_email(to_email: str, recipient_name: str, sender_name: str, amount, note: str | None = None) -> bool:
    """Sent to the person who just received money."""
    subject = f"You received ${amount} on Cloud Bank"
    note_line = f"\nNote: {note}" if note else ""
    text = (
        f"Hi {recipient_name},\n\n"
        f"{sender_name} sent you ${amount}.{note_line}\n\n"
        f"It's already reflected in your account balance."
    )
    html = f"""
      <div style="font-family:sans-serif; max-width:420px; margin:0 auto;">
        <h2 style="margin-bottom:4px;">Cloud Bank</h2>
        <p style="color:#333;">Hi {recipient_name},</p>
        <p style="color:#333;"><strong>{sender_name}</strong> sent you <strong>${amount}</strong>.</p>
        {f'<p style="color:#555; font-size:13px;">Note: {note}</p>' if note else ''}
        <p style="color:#555; font-size:13px;">It's already reflected in your account balance.</p>
      </div>
    """
    return send_email(to_email, subject, text, html)


def send_login_email(to_email: str, full_name: str, when_str: str) -> bool:
    """Sent to a person's own email every time they successfully log in -
    a lightweight "was this you?" notice. Never blocks the login itself;
    callers should fire-and-forget this (see users-service /login)."""
    subject = "New sign-in to your Cloud Bank account"
    text = (
        f"Hi {full_name},\n\n"
        f"Your Cloud Bank account was just signed into at {when_str}.\n\n"
        f"If this was you, no action is needed. If it wasn't, change your "
        f"password and contact support right away."
    )
    html = f"""
      <div style="font-family:sans-serif; max-width:420px; margin:0 auto;">
        <h2 style="margin-bottom:4px;">Cloud Bank</h2>
        <p style="color:#333;">Hi {full_name},</p>
        <p style="color:#333;">Your account was just signed into at <strong>{when_str}</strong>.</p>
        <p style="color:#555; font-size:13px;">If this was you, no action is needed. If it wasn't,
        change your password and contact support right away.</p>
      </div>
    """
    return send_email(to_email, subject, text, html)
