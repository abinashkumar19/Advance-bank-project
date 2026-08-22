output "cluster_endpoint" {
  value = aws_rds_cluster.users.endpoint
}

output "cluster_reader_endpoint" {
  value = aws_rds_cluster.users.reader_endpoint
}

output "database_name" {
  value = aws_rds_cluster.users.database_name
}

output "creds_bucket_name" {
  value = aws_s3_bucket.users_db_creds.bucket
}

output "creds_object_key" {
  value = aws_s3_object.users_db_creds.key
}

output "secret_access_policy_arn" {
  value = aws_iam_policy.users_db_secret_access.arn
}

output "lambda_sg_id" {
  description = "Security group to attach to any Lambda that needs to reach this cluster (e.g. users-db-sync)"
  value       = aws_security_group.users_db_sync_lambda.id
}

output "master_username" {
  value = aws_rds_cluster.users.master_username
}

output "master_password" {
  value     = random_password.db_master.result
  sensitive = true
}
