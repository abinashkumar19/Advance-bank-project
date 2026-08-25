variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "rds_master_username" {
  type = string
}

variable "rds_master_password" {
  type      = string
  sensitive = true
}

variable "rds_endpoint" {
  type = string
}

variable "rds_database_name" {
  type = string
}

variable "enable_guardduty" {
  description = "GuardDuty bills per-account/region - set false to skip if this AWS account already has a detector enabled elsewhere"
  type        = bool
  default     = true
}
