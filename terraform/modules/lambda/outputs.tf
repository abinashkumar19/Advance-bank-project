output "transactions_history_api_url" {
  value = aws_apigatewayv2_stage.transactions_history.invoke_url
}

output "telegram_secret_name" {
  value = aws_secretsmanager_secret.telegram.name
}
