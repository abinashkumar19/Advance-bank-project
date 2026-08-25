output "accounts_table_name" {
  value = aws_dynamodb_table.accounts.name
}

output "accounts_table_arn" {
  value = aws_dynamodb_table.accounts.arn
}

output "transfers_table_name" {
  value = aws_dynamodb_table.transfers.name
}

output "transfers_table_arn" {
  value = aws_dynamodb_table.transfers.arn
}

output "app_access_policy_arn" {
  value = aws_iam_policy.dynamodb_app_access.arn
}

output "users_table_stream_arn" {
  value = aws_dynamodb_table.users.stream_arn
}

output "generic_tables" {
  description = "Map of service name -> table (name/arn) for the generic id-keyed tables"
  value = {
    for name, t in aws_dynamodb_table.generic : name => {
      name = t.name
      arn  = t.arn
    }
  }
}
