variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "account_id" {
  type = string
}

# --- from the dynamodb module ---
variable "accounts_table_name" {
  type = string
}

variable "accounts_table_arn" {
  type = string
}

variable "transfers_table_name" {
  type = string
}

variable "transfers_table_arn" {
  type = string
}

variable "loans_table_name" {
  type = string
}

variable "loans_table_arn" {
  type = string
}

variable "fraud_table_name" {
  type = string
}

variable "fraud_table_arn" {
  type = string
}

# --- from the messaging module ---
variable "fraud_check_queue_arn" {
  type = string
}

variable "fraud_check_queue_url" {
  type = string
}
