variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "azs" {
  type = list(string)
}

variable "private_subnet_cidrs" {
  type = list(string)
}

variable "public_subnet_cidrs" {
  type = list(string)
}

variable "eks_cluster_name" {
  description = "Used only for the kubernetes.io/cluster/<name> subnet tags EKS + the ALB controller expect"
  type        = string
}

variable "reuse_existing_vpc" {
  description = "Set true ONLY if you already have a VPC tagged '<project>-<environment>-vpc' from a previous apply that you want to reuse instead of creating a new one (e.g. a sandbox/training AWS account capped at 1 VPC per region). Leave false in every normal case - this must be a stable, deliberately-set value, never auto-detected, or a successful VPC creation on one apply can make the NEXT plan think the VPC 'shouldn't exist' and try to destroy it."
  type        = bool
  default     = false
}
