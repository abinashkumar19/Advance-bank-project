output "transaction_history_bucket_name" {
  value = aws_s3_bucket.transaction_history.bucket
}

output "transaction_history_bucket_arn" {
  value = aws_s3_bucket.transaction_history.arn
}
