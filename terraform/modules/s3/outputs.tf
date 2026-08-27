output "transaction_history_bucket_name" {
  value = aws_s3_bucket.transaction_history.bucket
}

output "transaction_history_bucket_arn" {
  value = aws_s3_bucket.transaction_history.arn
}

output "ollama_model_cache_bucket_name" {
  value = aws_s3_bucket.ollama_model_cache.bucket
}

output "ollama_model_cache_access_policy_arn" {
  value = aws_iam_policy.ollama_model_cache_access.arn
}
