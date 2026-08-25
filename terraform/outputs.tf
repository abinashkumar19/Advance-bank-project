output "eks_cluster_name" {
  value = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "configure_kubectl" {
  description = "Run this to set up kubectl access"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "ecr_repository_urls" {
  description = "Map of service name -> ECR repository URL"
  value       = module.ecr.repository_urls
}

output "dynamodb_accounts_table" {
  value = module.dynamodb.accounts_table_name
}

output "backend_irsa_role_arn" {
  description = "Put this on the Kubernetes ServiceAccount annotation eks.amazonaws.com/role-arn"
  value       = module.backend_irsa.iam_role_arn
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "users_db_endpoint" {
  description = "Aurora MySQL writer endpoint (replica of the users DynamoDB table, fed by users-db-sync)"
  value       = module.rds.cluster_endpoint
}

output "users_db_reader_endpoint" {
  description = "Aurora MySQL reader endpoint - load-balances across all reader instances (read-only queries only)"
  value       = module.rds.cluster_reader_endpoint
}

output "users_db_name" {
  value = module.rds.database_name
}

output "users_db_creds_bucket" {
  description = "S3 bucket holding the Aurora MySQL credentials object used by the users-db-sync Lambda"
  value       = module.rds.creds_bucket_name
}

output "users_db_creds_key" {
  description = "S3 object key (inside users_db_creds_bucket) holding the DB credentials JSON"
  value       = module.rds.creds_object_key
}

output "transaction_history_bucket" {
  description = "Per-user activity history bucket (folder per user_id/account_id)"
  value       = module.s3.transaction_history_bucket_name
}

output "transactions_history_api_url" {
  description = "Base URL of the general-purpose per-user history API Gateway (Lambda-backed, reads/writes S3)"
  value       = module.lambda.transactions_history_api_url
}

output "telegram_secret_name" {
  description = "Secrets Manager secret name notification-writer Lambda reads Telegram bot credentials from. Populated out-of-band by the deploy workflow, not by Terraform - see terraform/modules/lambda/main.tf."
  value       = module.lambda.telegram_secret_name
}

output "opensearch_endpoint" {
  value = module.search.opensearch_endpoint
}

output "opensearch_dashboards_endpoint" {
  value = module.search.opensearch_dashboards_endpoint
}

output "redis_endpoint" {
  value = module.search.redis_endpoint
}

output "sqs_fraud_check_queue_url" {
  value = module.messaging.fraud_check_queue_url
}

output "sqs_doc_generation_queue_url" {
  value = module.messaging.doc_generation_queue_url
}

output "eventbridge_bus_name" {
  value = module.messaging.event_bus_name
}

output "app_log_group_name" {
  value = module.observability.log_group_name
}

output "acm_certificate_validation_records" {
  value = module.networking.acm_certificate_validation_records
}

output "acm_certificate_arn" {
  value = module.networking.acm_certificate_arn
}

output "credit_score_api_url" {
  value = module.scoring.credit_score_api_url
}

output "loan_approval_state_machine_arn" {
  value = module.scoring.loan_approval_state_machine_arn
}

output "rds_secret_arn" {
  description = "Secrets Manager ARN holding the Aurora MySQL master credentials"
  value       = module.security.rds_secret_arn
}

output "guardduty_detector_id" {
  value = module.security.guardduty_detector_id
}

output "kinesis_stream_name" {
  value = module.analytics.kinesis_stream_name
}

output "athena_workgroup_name" {
  value = module.analytics.athena_workgroup_name
}

output "grafana_admin_password" {
  value     = module.monitoring.grafana_admin_password
  sensitive = true
}
