# SNS topic published to by the users-service on first-time registration.
resource "aws_sns_topic" "user_registered" {
  name = "${var.project_name}-${var.environment}-user-registered"
}

resource "aws_iam_policy" "sns_publish_user_registered" {
  name        = "${var.project_name}-${var.environment}-sns-publish-user-registered"
  description = "Allows the users-service to publish to the user-registered SNS topic"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PublishUserRegistered"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.user_registered.arn
      }
    ]
  })
}

# Real email subscriber. Set var.notification_email to a real address; the
# subscription is only created once that's non-empty, and AWS will send a
# confirmation email that must be clicked before delivery starts.
resource "aws_sns_topic_subscription" "user_registered_email" {
  count     = var.notification_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.user_registered.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

# ---------------------------------------------------------------------------
# In-app subscriber: SNS -> SQS -> notification-writer Lambda -> the same
# DynamoDB table the notifications-service microservice already serves
# from (GET /notifications/items).
# ---------------------------------------------------------------------------

resource "aws_sqs_queue" "user_registered_notifications" {
  name                       = "${var.project_name}-${var.environment}-user-registered-notifications"
  visibility_timeout_seconds = 30
  message_retention_seconds  = 86400
}

resource "aws_sqs_queue_policy" "user_registered_notifications" {
  queue_url = aws_sqs_queue.user_registered_notifications.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowSnsSend"
        Effect    = "Allow"
        Principal = { Service = "sns.amazonaws.com" }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.user_registered_notifications.arn
        Condition = {
          ArnEquals = { "aws:SourceArn" = aws_sns_topic.user_registered.arn }
        }
      }
    ]
  })
}

resource "aws_sns_topic_subscription" "user_registered_sqs" {
  topic_arn = aws_sns_topic.user_registered.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.user_registered_notifications.arn
}
