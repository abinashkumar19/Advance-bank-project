output "credit_score_api_url" {
  value = aws_apigatewayv2_stage.credit_score.invoke_url
}

output "loan_approval_state_machine_arn" {
  value = aws_sfn_state_machine.loan_approval.arn
}
