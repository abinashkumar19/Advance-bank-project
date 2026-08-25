# ---------------------------------------------------------------------------
# Lambda: transactions-history (S3 read/write) behind API Gateway
# ---------------------------------------------------------------------------

data "archive_file" "transactions_history" {
  type        = "zip"
  source_dir  = "${path.module}/../../../backend/lambdas/transactions_history"
  output_path = "${path.module}/../../build/transactions_history.zip"
}

resource "aws_iam_role" "transactions_history_lambda" {
  name = "${var.project_name}-${var.environment}-txn-history-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "transactions_history_lambda" {
  name = "s3-access"
  role = aws_iam_role.transactions_history_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
        Resource = [
          var.transaction_history_bucket_arn,
          "${var.transaction_history_bucket_arn}/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.aws_region}:${var.account_id}:*"
      }
    ]
  })
}

resource "aws_lambda_function" "transactions_history" {
  function_name    = "${var.project_name}-${var.environment}-transactions-history"
  role             = aws_iam_role.transactions_history_lambda.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 15
  filename         = data.archive_file.transactions_history.output_path
  source_code_hash = data.archive_file.transactions_history.output_base64sha256

  environment {
    variables = {
      TRANSACTION_HISTORY_BUCKET = var.transaction_history_bucket_name
    }
  }
}

resource "aws_apigatewayv2_api" "transactions_history" {
  name          = "${var.project_name}-${var.environment}-transactions-history"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "transactions_history" {
  api_id                 = aws_apigatewayv2_api.transactions_history.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.transactions_history.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "write_history" {
  api_id    = aws_apigatewayv2_api.transactions_history.id
  route_key = "POST /history"
  target    = "integrations/${aws_apigatewayv2_integration.transactions_history.id}"
}

resource "aws_apigatewayv2_route" "read_history" {
  api_id    = aws_apigatewayv2_api.transactions_history.id
  route_key = "GET /history/{account_id}"
  target    = "integrations/${aws_apigatewayv2_integration.transactions_history.id}"
}

resource "aws_apigatewayv2_stage" "transactions_history" {
  api_id      = aws_apigatewayv2_api.transactions_history.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "transactions_history_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.transactions_history.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.transactions_history.execution_arn}/*/*"
}

# ---------------------------------------------------------------------------
# Lambda: users-db-sync (DynamoDB Streams "users" -> Aurora MySQL "users")
# ---------------------------------------------------------------------------

resource "null_resource" "users_db_sync_deps" {
  triggers = {
    requirements_hash = filesha256("${path.module}/../../../backend/lambdas/users_db_sync/requirements.txt")
  }

  provisioner "local-exec" {
    command = "python3 -m pip install -r ${path.module}/../../../backend/lambdas/users_db_sync/requirements.txt -t ${path.module}/../../../backend/lambdas/users_db_sync --upgrade --no-cache-dir"
  }
}

data "archive_file" "users_db_sync" {
  type        = "zip"
  source_dir  = "${path.module}/../../../backend/lambdas/users_db_sync"
  output_path = "${path.module}/../../build/users_db_sync.zip"
  excludes    = ["requirements.txt"]
  depends_on  = [null_resource.users_db_sync_deps]
}

resource "aws_iam_role" "users_db_sync_lambda" {
  name = "${var.project_name}-${var.environment}-users-db-sync-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "users_db_sync_lambda_vpc" {
  role       = aws_iam_role.users_db_sync_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy_attachment" "users_db_sync_lambda_db_creds" {
  role       = aws_iam_role.users_db_sync_lambda.name
  policy_arn = var.rds_secret_access_policy_arn
}

resource "aws_iam_role_policy" "users_db_sync_lambda_stream" {
  name = "dynamodb-stream-and-logs"
  role = aws_iam_role.users_db_sync_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetRecords",
          "dynamodb:GetShardIterator",
          "dynamodb:DescribeStream",
          "dynamodb:ListStreams",
        ]
        Resource = var.users_table_stream_arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.aws_region}:${var.account_id}:*"
      }
    ]
  })
}

resource "aws_lambda_function" "users_db_sync" {
  function_name    = "${var.project_name}-${var.environment}-users-db-sync"
  role             = aws_iam_role.users_db_sync_lambda.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 30
  filename         = data.archive_file.users_db_sync.output_path
  source_code_hash = data.archive_file.users_db_sync.output_base64sha256

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [var.rds_lambda_sg_id]
  }

  environment {
    variables = {
      DB_CREDS_BUCKET = var.rds_creds_bucket_name
      DB_CREDS_KEY     = var.rds_creds_object_key
    }
  }

  depends_on = [aws_iam_role_policy_attachment.users_db_sync_lambda_vpc]
}

resource "aws_lambda_event_source_mapping" "users_db_sync" {
  event_source_arn  = var.users_table_stream_arn
  function_name     = aws_lambda_function.users_db_sync.arn
  starting_position = "LATEST"
  batch_size        = 10
}

# ---------------------------------------------------------------------------
# Lambda: notification-writer (SQS -> DynamoDB "notifications" table)
# ---------------------------------------------------------------------------

# Container only - deliberately NO aws_secretsmanager_secret_version here.
# The real bot token/chat id are written directly with
# `aws secretsmanager put-secret-value` from GitHub Actions secrets (see
# .github/workflows/deploy.yml, "Sync Telegram credentials to Secrets
# Manager"), so the value itself never flows through a Terraform variable
# or lands in the state file - same reasoning as the Alertmanager config
# secret in terraform/modules/monitoring.
resource "aws_secretsmanager_secret" "telegram" {
  name = "${var.project_name}-${var.environment}-telegram-notifications"
}

data "archive_file" "notification_writer" {
  type        = "zip"
  source_dir  = "${path.module}/../../../backend/lambdas/notification_writer"
  output_path = "${path.module}/../../build/notification_writer.zip"
}

resource "aws_iam_role" "notification_writer_lambda" {
  name = "${var.project_name}-${var.environment}-notification-writer-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "notification_writer_lambda" {
  name = "sqs-and-dynamodb-access"
  role = aws_iam_role.notification_writer_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = var.user_registered_queue_arn
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"]
        Resource = var.notifications_table_arn
      },
      {
        Effect   = "Allow"
        Action   = ["ses:SendEmail", "ses:SendRawEmail"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.telegram.arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.aws_region}:${var.account_id}:*"
      }
    ]
  })
}

resource "aws_lambda_function" "notification_writer" {
  function_name    = "${var.project_name}-${var.environment}-notification-writer"
  role             = aws_iam_role.notification_writer_lambda.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 15
  filename         = data.archive_file.notification_writer.output_path
  source_code_hash = data.archive_file.notification_writer.output_base64sha256

  environment {
    variables = {
      NOTIFICATIONS_TABLE  = var.notifications_table_name
      SES_SENDER_EMAIL     = var.ses_sender_email
      TELEGRAM_SECRET_NAME = aws_secretsmanager_secret.telegram.name
    }
  }
}

resource "aws_lambda_event_source_mapping" "notification_writer_sqs" {
  event_source_arn = var.user_registered_queue_arn
  function_name    = aws_lambda_function.notification_writer.arn
  batch_size       = 10
}
