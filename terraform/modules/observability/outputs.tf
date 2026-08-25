output "xray_policy_arn" {
  value = aws_iam_policy.xray_write_access.arn
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.app.name
}
