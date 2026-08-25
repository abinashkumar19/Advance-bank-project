# ---------------------------------------------------------------------------
# Analytics - Kinesis (live transaction event stream) + Glue/Athena (SQL
# queries directly over the transaction-history S3 bucket, no ETL needed).
# ---------------------------------------------------------------------------

# Live stream of transaction events, in addition to the EventBridge bus -
# EventBridge is for routing single events to services (fraud-check queue,
# etc), Kinesis is for anything that wants the full ordered firehose (a
# future real-time dashboard, a fraud model retraining pipeline, etc).
resource "aws_kinesis_stream" "transactions" {
  name             = "${var.project_name}-${var.environment}-transactions"
  shard_count      = 1
  retention_period = 24

  stream_mode_details {
    stream_mode = "PROVISIONED"
  }
}

resource "aws_iam_policy" "kinesis_app_access" {
  name        = "${var.project_name}-${var.environment}-kinesis-app-access"
  description = "Allows the transactions-service to publish to the Kinesis transaction stream"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "KinesisPublish"
        Effect   = "Allow"
        Action   = ["kinesis:PutRecord", "kinesis:PutRecords"]
        Resource = aws_kinesis_stream.transactions.arn
      }
    ]
  })
}

# --- Glue + Athena: SQL over the transaction-history S3 bucket -----------

resource "aws_glue_catalog_database" "transactions" {
  name = "${var.project_name}_${var.environment}_transactions"
}

# Points at the bucket; a Glue Crawler (run manually or on a schedule once
# real data exists) infers the schema and creates/updates the actual table.
resource "aws_glue_crawler" "transaction_history" {
  name          = "${var.project_name}-${var.environment}-transaction-history"
  role          = aws_iam_role.glue_crawler.arn
  database_name = aws_glue_catalog_database.transactions.name

  s3_target {
    path = "s3://${var.transaction_history_bucket_name}/"
  }

  schedule = "cron(0 3 * * ? *)" # nightly at 3am UTC
}

resource "aws_iam_role" "glue_crawler" {
  name = "${var.project_name}-${var.environment}-glue-crawler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "glue.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "glue_crawler_service_role" {
  role       = aws_iam_role.glue_crawler.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy" "glue_crawler_s3_access" {
  name = "s3-read"
  role = aws_iam_role.glue_crawler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = [var.transaction_history_bucket_arn, "${var.transaction_history_bucket_arn}/*"]
      }
    ]
  })
}

resource "aws_s3_bucket" "athena_results" {
  bucket = "${var.project_name}-${var.environment}-athena-results-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "athena_results" {
  bucket                  = aws_s3_bucket.athena_results.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_athena_workgroup" "transactions" {
  name = "${var.project_name}-${var.environment}-transactions"

  configuration {
    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.bucket}/"
    }
  }
}

data "aws_caller_identity" "current" {}
