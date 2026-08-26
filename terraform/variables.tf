variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name, used as prefix for resources"
  type        = string
  default     = "veerabank"
}

variable "environment" {
  description = "Environment name (dev/stage/prod)"
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.20.0.0/16"
}

variable "azs" {
  description = "Availability zones to spread subnets across"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.20.1.0/24", "10.20.2.0/24"]
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.20.101.0/24", "10.20.102.0/24"]
}

variable "eks_cluster_version" {
  description = "Kubernetes version for EKS"
  type        = string
  default     = "1.34"
}

variable "node_instance_types" {
  description = "EC2 instance types for the EKS managed node group"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_desired_size" {
  type    = number
  default = 8
}

variable "node_min_size" {
  type    = number
  default = 8
}

variable "node_max_size" {
  type    = number
  default = 9
}

variable "ollama_node_instance_types" {
  description = "Dedicated instance type for the self-hosted Ollama chatbot model server (see k8s/services/ollama-deployment.yaml). m6i.2xlarge: 8 vCPU / 32GiB - standard compute family, no special EC2 service quota or IAM/SCP approval needed (unlike G/VT GPU instances, which default to a 0-vCPU quota on many accounts). Not as fast as a GPU, but a dedicated node the model doesn't have to share with 30+ other pods is still a real step up from the shared t3.medium pool. Billed whether or not it's actively serving requests."
  type        = list(string)
  default     = ["m6i.2xlarge"]
}

variable "ollama_node_desired_size" {
  description = "Just 1 - this node group exists solely for the single-replica ollama Deployment. Bumping this without also scaling ollama's own replica count just wastes money on an idle node."
  type        = number
  default     = 1
}

variable "ollama_node_min_size" {
  type    = number
  default = 1
}

variable "ollama_node_max_size" {
  type    = number
  default = 1
}

variable "dynamodb_billing_mode" {
  description = "PAY_PER_REQUEST (on-demand) or PROVISIONED"
  type        = string
  default     = "PAY_PER_REQUEST"
}

variable "notification_email" {
  description = "Real email address to subscribe to the user-registered SNS topic (ops/admin alert copy). Leave blank to skip creating the email subscription."
  type        = string
  default     = ""
}

variable "ses_sender_email" {
  description = "Verified SES sender address used to email each new user a personal welcome message on registration. Must be verified in SES (AWS emails a confirmation link - click it once). Leave blank to skip sending welcome emails."
  type        = string
  default     = ""
}

variable "app_domain_name" {
  description = "Domain name for the ACM certificate (e.g. bank.example.com). Leave blank to skip HTTPS/ACM setup."
  type        = string
  default     = ""
}

variable "opensearch_instance_type" {
  description = "Instance type for the OpenSearch domain (single node, dev-sized by default)"
  type        = string
  default     = "t3.small.search"
}

variable "redis_node_type" {
  description = "Instance type for the ElastiCache Redis node (single node, dev-sized by default)"
  type        = string
  default     = "cache.t3.micro"
}

variable "bedrock_model_id" {
  description = "Bedrock foundation model ID the chatbot service is allowed to invoke"
  type        = string
  default     = "anthropic.claude-3-5-sonnet-20241022-v2:0"
}

variable "enable_guardduty" {
  description = "GuardDuty bills per-account/region - set false if this AWS account already has a detector enabled elsewhere"
  type        = bool
  default     = true
}

variable "grafana_admin_password" {
  description = "Leave blank to auto-generate a random one (recommended - read it back via `terraform output grafana_admin_password`)"
  type        = string
  default     = ""
  sensitive   = true
}
