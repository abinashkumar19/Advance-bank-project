resource "aws_dynamodb_table" "accounts" {
  name         = "${var.project_name}-${var.environment}-accounts"
  billing_mode = var.dynamodb_billing_mode
  hash_key     = "account_id"

  attribute {
    name = "account_id"
    type = "S"
  }

  attribute {
    name = "user_id"
    type = "S"
  }

  attribute {
    name = "account_number"
    type = "S"
  }

  global_secondary_index {
    name            = "user_id-index"
    hash_key        = "user_id"
    projection_type = "ALL"
  }

  global_secondary_index {
    name            = "account_number-index"
    hash_key        = "account_number"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }
}

resource "aws_dynamodb_table" "transfers" {
  name         = "${var.project_name}-${var.environment}-transfers"
  billing_mode = var.dynamodb_billing_mode
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  attribute {
    name = "from_account_id"
    type = "S"
  }

  attribute {
    name = "to_account_id"
    type = "S"
  }

  global_secondary_index {
    name            = "from_account_id-index"
    hash_key        = "from_account_id"
    projection_type = "ALL"
  }

  global_secondary_index {
    name            = "to_account_id-index"
    hash_key        = "to_account_id"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }
}

resource "aws_dynamodb_table" "users" {
  name         = "${var.project_name}-${var.environment}-users"
  billing_mode = var.dynamodb_billing_mode
  hash_key     = "user_id"

  attribute {
    name = "user_id"
    type = "S"
  }

  attribute {
    name = "email"
    type = "S"
  }

  global_secondary_index {
    name            = "email-index"
    hash_key        = "email"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"
}

resource "aws_dynamodb_table" "otp_codes" {
  name         = "${var.project_name}-${var.environment}-otp_codes"
  billing_mode = var.dynamodb_billing_mode
  hash_key     = "email"

  attribute {
    name = "email"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  server_side_encryption {
    enabled = true
  }
}

resource "aws_dynamodb_table" "generic" {
  for_each = toset(var.generic_tables)

  name         = "${var.project_name}-${var.environment}-${each.value}"
  billing_mode = var.dynamodb_billing_mode
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  dynamic "attribute" {
    for_each = contains(var.user_indexed_generic_tables, each.value) ? [1] : []
    content {
      name = "user_id"
      type = "S"
    }
  }

  dynamic "global_secondary_index" {
    for_each = contains(var.user_indexed_generic_tables, each.value) ? [1] : []
    content {
      name            = "user_id-index"
      hash_key        = "user_id"
      projection_type = "ALL"
    }
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }
}

resource "aws_iam_policy" "dynamodb_app_access" {
  name        = "${var.project_name}-${var.environment}-dynamodb-app-access"
  description = "Allows the VeeraBank backend pods to read/write their DynamoDB tables"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AppTableAccess"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
          "dynamodb:Query",
          "dynamodb:Scan",
          "dynamodb:BatchGetItem",
          "dynamodb:BatchWriteItem",
          "dynamodb:ConditionCheckItem",
          "dynamodb:TransactGetItems",
          "dynamodb:TransactWriteItems"
        ]
        Resource = concat(
          [
            aws_dynamodb_table.accounts.arn,
            "${aws_dynamodb_table.accounts.arn}/index/*",
            aws_dynamodb_table.users.arn,
            "${aws_dynamodb_table.users.arn}/index/*",
            aws_dynamodb_table.transfers.arn,
            "${aws_dynamodb_table.transfers.arn}/index/*",
            aws_dynamodb_table.otp_codes.arn,
          ],
          [for t in aws_dynamodb_table.generic : t.arn],
          [for t in aws_dynamodb_table.generic : "${t.arn}/index/*"],
        )
      }
    ]
  })
}
