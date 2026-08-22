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

variable "private_subnet_ids" {
  type = list(string)
}

variable "ses_sender_email" {
  type    = string
  default = ""
}

# --- from the s3 module ---
variable "transaction_history_bucket_name" {
  type = string
}

variable "transaction_history_bucket_arn" {
  type = string
}

# --- from the dynamodb module ---
variable "users_table_stream_arn" {
  type = string
}

variable "notifications_table_name" {
  type = string
}

variable "notifications_table_arn" {
  type = string
}

# --- from the rds module ---
variable "rds_lambda_sg_id" {
  type = string
}

variable "rds_secret_access_policy_arn" {
  type = string
}

variable "rds_creds_bucket_name" {
  type = string
}

variable "rds_creds_object_key" {
  type = string
}

# --- from the sns module ---
variable "user_registered_queue_arn" {
  type = string
}
