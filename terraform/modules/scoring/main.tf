# ---------------------------------------------------------------------------
# Scoring - CIBIL-style credit scoring + explainable fraud risk scoring.
# ---------------------------------------------------------------------------

# --- credit-score Lambda (behind its own small API Gateway) ---------------

data "archive_file" "credit_score" {
  type        = "zip"
  source_dir  = "${path.module}/../../../backend/lambdas/credit_score"
  output_path = "${path.module}/../../build/credit_score.zip"
}

resource "aws_iam_role" "credit_score_lambda" {
  name = "${var.project_name}-${var.environment}-credit-score-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "credit_score_lambda" {
  name = "dynamodb-read-and-logs"
  role = aws_iam_role.credit_score_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["dynamodb:Query", "dynamodb:GetItem"]
        Resource = [
          var.accounts_table_arn, "${var.accounts_table_arn}/index/*",
          var.transfers_table_arn, "${var.transfers_table_arn}/index/*",
          var.loans_table_arn, "${var.loans_table_arn}/index/*",
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

resource "aws_lambda_function" "credit_score" {
  function_name    = "${var.project_name}-${var.environment}-credit-score"
  role             = aws_iam_role.credit_score_lambda.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 15
  filename         = data.archive_file.credit_score.output_path
  source_code_hash = data.archive_file.credit_score.output_base64sha256

  environment {
    variables = {
      ACCOUNTS_TABLE  = var.accounts_table_name
      TRANSFERS_TABLE = var.transfers_table_name
      LOANS_TABLE     = var.loans_table_name
    }
  }
}

resource "aws_apigatewayv2_api" "credit_score" {
  name          = "${var.project_name}-${var.environment}-credit-score"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "credit_score" {
  api_id                 = aws_apigatewayv2_api.credit_score.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.credit_score.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "credit_score" {
  api_id    = aws_apigatewayv2_api.credit_score.id
  route_key = "POST /score"
  target    = "integrations/${aws_apigatewayv2_integration.credit_score.id}"
}

resource "aws_apigatewayv2_stage" "credit_score" {
  api_id      = aws_apigatewayv2_api.credit_score.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "credit_score_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.credit_score.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.credit_score.execution_arn}/*/*"
}

# Also invokable directly by Step Functions (loan-approval workflow below).
resource "aws_lambda_permission" "credit_score_stepfunctions" {
  statement_id  = "AllowStepFunctionsInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.credit_score.function_name
  principal     = "states.amazonaws.com"
  source_arn    = aws_sfn_state_machine.loan_approval.arn
}

# --- fraud-score Lambda (consumes the fraud-check SQS queue) --------------

data "archive_file" "fraud_score" {
  type        = "zip"
  source_dir  = "${path.module}/../../../backend/lambdas/fraud_score"
  output_path = "${path.module}/../../build/fraud_score.zip"
}

resource "aws_iam_role" "fraud_score_lambda" {
  name = "${var.project_name}-${var.environment}-fraud-score-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "fraud_score_lambda" {
  name = "sqs-dynamodb-and-logs"
  role = aws_iam_role.fraud_score_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = var.fraud_check_queue_arn
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"]
        Resource = var.fraud_table_arn
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:Query"]
        Resource = [var.transfers_table_arn, "${var.transfers_table_arn}/index/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.aws_region}:${var.account_id}:*"
      }
    ]
  })
}

resource "aws_lambda_function" "fraud_score" {
  function_name    = "${var.project_name}-${var.environment}-fraud-score"
  role             = aws_iam_role.fraud_score_lambda.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 20
  filename         = data.archive_file.fraud_score.output_path
  source_code_hash = data.archive_file.fraud_score.output_base64sha256

  environment {
    variables = {
      FRAUD_TABLE     = var.fraud_table_name
      TRANSFERS_TABLE = var.transfers_table_name
    }
  }
}

resource "aws_lambda_event_source_mapping" "fraud_score_sqs" {
  event_source_arn = var.fraud_check_queue_arn
  function_name    = aws_lambda_function.fraud_score.arn
  batch_size       = 5
}

# --- Step Functions: loan-approval workflow --------------------------------

resource "aws_iam_role" "loan_approval_sfn" {
  name = "${var.project_name}-${var.environment}-loan-approval-sfn"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "loan_approval_sfn" {
  name = "invoke-credit-score-lambda"
  role = aws_iam_role.loan_approval_sfn.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = aws_lambda_function.credit_score.arn
      }
    ]
  })
}

resource "aws_sfn_state_machine" "loan_approval" {
  name     = "${var.project_name}-${var.environment}-loan-approval"
  role_arn = aws_iam_role.loan_approval_sfn.arn

  definition = templatefile("${path.module}/state_machine.asl.json", {
    credit_score_lambda_arn = aws_lambda_function.credit_score.arn
  })
}
