output "user_registered_topic_arn" {
  value = aws_sns_topic.user_registered.arn
}

output "publish_policy_arn" {
  value = aws_iam_policy.sns_publish_user_registered.arn
}

output "user_registered_queue_arn" {
  value = aws_sqs_queue.user_registered_notifications.arn
}

output "user_registered_queue_id" {
  value = aws_sqs_queue.user_registered_notifications.id
}
