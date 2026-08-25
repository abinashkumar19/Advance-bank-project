variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "eks_oidc_provider_arn" {
  type = string
}

variable "policy_arns" {
  description = "Map of name -> IAM policy ARN to attach to the backend app's IRSA role"
  type        = map(string)
}
