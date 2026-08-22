output "kinesis_stream_arn" {
  value = aws_kinesis_stream.transactions.arn
}

output "kinesis_stream_name" {
  value = aws_kinesis_stream.transactions.name
}

output "kinesis_app_access_policy_arn" {
  value = aws_iam_policy.kinesis_app_access.arn
}

output "glue_database_name" {
  value = aws_glue_catalog_database.transactions.name
}

output "athena_workgroup_name" {
  value = aws_athena_workgroup.transactions.name
}
