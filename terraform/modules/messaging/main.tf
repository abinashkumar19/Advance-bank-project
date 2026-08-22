# ---------------------------------------------------------------------------
# Messaging & Async - SQS (work queues) + EventBridge (event bus)
# ---------------------------------------------------------------------------

resource "aws_sqs_queue" "dlq" {
  name                      = "${var.project_name}-${var.environment}-dlq"
  message_retention_seconds = 1209600 # 14 days
}

resource "aws_sqs_queue" "fraud_check" {
  name                       = "${var.project_name}-${var.environment}-fraud-check"
  visibility_timeout_seconds = 30
  message_retention_seconds  = 345600 # 4 days

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount      = 5
  })
}

resource "aws_sqs_queue" "doc_generation" {
  name                       = "${var.project_name}-${var.environment}-doc-generation"
  visibility_timeout_seconds = 120
  message_retention_seconds  = 345600

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount      = 3
  })
}

resource "aws_cloudwatch_event_bus" "app" {
  name = "${var.project_name}-${var.environment}-events"
}

resource "aws_cloudwatch_event_rule" "transaction_completed" {
  name           = "${var.project_name}-${var.environment}-transaction-completed"
  event_bus_name = aws_cloudwatch_event_bus.app.name

  event_pattern = jsonencode({
    source        = ["${var.project_name}.transactions"]
    "detail-type" = ["TransactionCompleted"]
  })
}

resource "aws_cloudwatch_event_target" "transaction_completed_to_fraud_check" {
  rule           = aws_cloudwatch_event_rule.transaction_completed.name
  event_bus_name = aws_cloudwatch_event_bus.app.name
  arn            = aws_sqs_queue.fraud_check.arn
}

resource "aws_sqs_queue_policy" "fraud_check_allow_eventbridge" {
  queue_url = aws_sqs_queue.fraud_check.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowEventBridge"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.fraud_check.arn
        Condition = {
          ArnEquals = { "aws:SourceArn" = aws_cloudwatch_event_rule.transaction_completed.arn }
        }
      }
    ]
  })
}

resource "aws_iam_policy" "messaging_app_access" {
  name        = "${var.project_name}-${var.environment}-messaging-app-access"
  description = "Allows backend pods to send/receive SQS messages and publish EventBridge events"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SqsAccess"
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = [
          aws_sqs_queue.fraud_check.arn,
          aws_sqs_queue.doc_generation.arn,
          aws_sqs_queue.dlq.arn
        ]
      },
      {
        Sid      = "EventBridgePublish"
        Effect   = "Allow"
        Action   = ["events:PutEvents"]
        Resource = [aws_cloudwatch_event_bus.app.arn]
      }
    ]
  })
}
