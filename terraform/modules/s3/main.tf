# ---------------------------------------------------------------------------
# S3 - durable store for user transaction history. Every deposit/withdrawal
# processed by the transactions-service is written here (via the
# transactions-history Lambda) instead of DynamoDB, and read back the same
# way for statements/history views.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "transaction_history" {
  bucket = "${var.project_name}-${var.environment}-transaction-history-${var.account_id}"
}

resource "aws_s3_bucket_versioning" "transaction_history" {
  bucket = aws_s3_bucket.transaction_history.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "transaction_history" {
  bucket = aws_s3_bucket.transaction_history.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "transaction_history" {
  bucket                  = aws_s3_bucket.transaction_history.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# S3 - model cache for the self-hosted Ollama chatbot model server (see
# k8s/services/ollama-deployment.yaml). Pulling a multi-GB model from
# Ollama's public registry over the internet is slow and unpredictable;
# pulling the same files from an S3 bucket in the same AWS region is fast
# and consistent, similar to why ECR pulls are fast for every other
# service's container images. This bucket starts empty - the ollama pod's
# init container tries to restore from it first (fast path, no-op if
# nothing's been seeded yet) and falls back to a normal internet pull if
# the model isn't there. See k8s/services/ollama-seed-s3-job.yaml for the
# one-time job that seeds this bucket after that first (slow) pull.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "ollama_model_cache" {
  bucket = "${var.project_name}-${var.environment}-ollama-model-cache-${var.account_id}"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "ollama_model_cache" {
  bucket = aws_s3_bucket.ollama_model_cache.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "ollama_model_cache" {
  bucket                  = aws_s3_bucket.ollama_model_cache.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Model files are large and content-addressed by Ollama (blobs are named
# by hash, never change once written) - no versioning needed here, unlike
# transaction_history above where every historical version matters.
# A lifecycle rule isn't added either: unlike normal cache data, these
# blobs should persist indefinitely (until you deliberately change models).

resource "aws_iam_policy" "ollama_model_cache_access" {
  name = "${var.project_name}-${var.environment}-ollama-model-cache-access"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.ollama_model_cache.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "${aws_s3_bucket.ollama_model_cache.arn}/*"
      }
    ]
  })
}
