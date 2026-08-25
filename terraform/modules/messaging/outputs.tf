output "app_access_policy_arn" {
  value = aws_iam_policy.messaging_app_access.arn
}

output "fraud_check_queue_url" {
  value = aws_sqs_queue.fraud_check.id
}

output "fraud_check_queue_arn" {
  value = aws_sqs_queue.fraud_check.arn
}

output "doc_generation_queue_url" {
  value = aws_sqs_queue.doc_generation.id
}

output "event_bus_name" {
  value = aws_cloudwatch_event_bus.app.name
}
