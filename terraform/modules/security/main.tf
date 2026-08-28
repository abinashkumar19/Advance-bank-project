# ---------------------------------------------------------------------------
# Security - AWS Secrets Manager (rotatable credential store, alongside the
# existing S3 JSON object the users-db-sync Lambda already reads - this is
# the standard AWS-native mechanism and is what any new integration should
# read from going forward) + GuardDuty (account-wide threat detection).
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "rds_master" {
  name        = "${var.project_name}/${var.environment}/rds-master-credentials"
  description = "Aurora MySQL (users-db) master credentials"
  # Dev/demo environment: skip the default 30-day recovery window - see
  # the identical comment on aws_secretsmanager_secret.telegram in
  # terraform/modules/lambda/main.tf for why this matters.
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "rds_master" {
  secret_id = aws_secretsmanager_secret.rds_master.id
  secret_string = jsonencode({
    username = var.rds_master_username
    password = var.rds_master_password
    host     = var.rds_endpoint
    dbname   = var.rds_database_name
    port     = 3306
  })
}

resource "aws_iam_policy" "read_rds_secret" {
  name        = "${var.project_name}-${var.environment}-read-rds-secret"
  description = "Allows reading the RDS master credentials from Secrets Manager"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadRdsSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.rds_master.arn
      }
    ]
  })
}

# GuardDuty - continuous threat detection across CloudTrail, VPC Flow Logs,
# and DNS logs. Zero infrastructure to manage; findings show up in the
# GuardDuty console and can be wired to EventBridge/SNS for alerting.
resource "aws_guardduty_detector" "main" {
  count  = var.enable_guardduty ? 1 : 0
  enable = true

  finding_publishing_frequency = "FIFTEEN_MINUTES"
}
