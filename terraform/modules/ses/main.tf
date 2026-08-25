# SES sender identity for the welcome email sent by notification-writer.
# SES sandbox: both sender AND every recipient must be verified before mail
# actually sends. AWS emails a confirmation link to the sender - click it once.
resource "aws_ses_email_identity" "sender" {
  count = var.ses_sender_email != "" ? 1 : 0
  email = var.ses_sender_email
}
