output "rds_secret_arn" {
  value = aws_secretsmanager_secret.rds_master.arn
}

output "read_rds_secret_policy_arn" {
  value = aws_iam_policy.read_rds_secret.arn
}

output "guardduty_detector_id" {
  value = var.enable_guardduty ? aws_guardduty_detector.main[0].id : null
}
