terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.5"
    }
  }

  # Remote state - S3 bucket + DynamoDB lock table (create once, see README).
  backend "s3" {
    bucket = "veerabank-tfstate-693148422147-7940574"
    key            = "eks-dynamodb/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "veerabank-terraform-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", module.eks.cluster_name,
      "--region", var.aws_region
    ]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = [
        "eks", "get-token",
        "--cluster-name", module.eks.cluster_name,
        "--region", var.aws_region
      ]
    }
  }
}

data "aws_caller_identity" "current" {}

# =============================================================================
# Module wiring - see README.md "Module graph" for the dependency diagram.
# =============================================================================

module "vpc" {
  source = "./modules/vpc"

  project_name          = var.project_name
  environment           = var.environment
  vpc_cidr              = var.vpc_cidr
  azs                   = var.azs
  private_subnet_cidrs  = var.private_subnet_cidrs
  public_subnet_cidrs   = var.public_subnet_cidrs
  eks_cluster_name      = "${var.project_name}-${var.environment}-eks"
  reuse_existing_vpc    = var.reuse_existing_vpc
}

module "eks" {
  source = "./modules/eks"

  project_name         = var.project_name
  environment          = var.environment
  aws_region           = var.aws_region
  vpc_id               = module.vpc.vpc_id
  private_subnet_ids   = module.vpc.private_subnet_ids
  eks_cluster_version  = var.eks_cluster_version
  node_instance_types  = var.node_instance_types
  node_min_size        = var.node_min_size
  node_max_size        = var.node_max_size
  node_desired_size    = var.node_desired_size
}

module "dynamodb" {
  source = "./modules/dynamodb"

  project_name                  = var.project_name
  environment                   = var.environment
  dynamodb_billing_mode         = var.dynamodb_billing_mode
  generic_tables               = local.generic_tables
  user_indexed_generic_tables  = local.user_indexed_generic_tables
}

module "s3" {
  source = "./modules/s3"

  project_name = var.project_name
  environment  = var.environment
  account_id   = data.aws_caller_identity.current.account_id
}

module "ecr" {
  source = "./modules/ecr"

  project_name = var.project_name
  all_images   = local.all_images
}

module "sns" {
  source = "./modules/sns"

  project_name        = var.project_name
  environment         = var.environment
  notification_email  = var.notification_email
}

module "ses" {
  source = "./modules/ses"

  ses_sender_email = var.ses_sender_email
}

module "rds" {
  source = "./modules/rds"

  project_name        = var.project_name
  environment         = var.environment
  vpc_id              = module.vpc.vpc_id
  private_subnet_ids  = module.vpc.private_subnet_ids
  account_id          = data.aws_caller_identity.current.account_id
  aws_region          = var.aws_region
}

module "lambda" {
  source = "./modules/lambda"

  project_name        = var.project_name
  environment         = var.environment
  aws_region          = var.aws_region
  account_id          = data.aws_caller_identity.current.account_id
  private_subnet_ids  = module.vpc.private_subnet_ids
  ses_sender_email    = var.ses_sender_email

  transaction_history_bucket_name = module.s3.transaction_history_bucket_name
  transaction_history_bucket_arn  = module.s3.transaction_history_bucket_arn

  users_table_stream_arn    = module.dynamodb.users_table_stream_arn
  notifications_table_name  = module.dynamodb.generic_tables["notifications"].name
  notifications_table_arn   = module.dynamodb.generic_tables["notifications"].arn

  rds_lambda_sg_id              = module.rds.lambda_sg_id
  rds_secret_access_policy_arn  = module.rds.secret_access_policy_arn
  rds_creds_bucket_name         = module.rds.creds_bucket_name
  rds_creds_object_key          = module.rds.creds_object_key

  user_registered_queue_arn = module.sns.user_registered_queue_arn
}

module "observability" {
  source = "./modules/observability"

  project_name           = var.project_name
  environment             = var.environment
  eks_cluster_name        = module.eks.cluster_name
  eks_oidc_provider_arn   = module.eks.oidc_provider_arn

  # See modules/observability/main.tf - must come strictly after the ALB
  # controller's helm release inside module.eks, not just after the
  # cluster exists.
  depends_on = [module.eks]
}

module "messaging" {
  source = "./modules/messaging"

  project_name = var.project_name
  environment  = var.environment
}

module "search" {
  source = "./modules/search"

  project_name                = var.project_name
  environment                 = var.environment
  vpc_id                      = module.vpc.vpc_id
  private_subnet_ids          = module.vpc.private_subnet_ids
  eks_node_security_group_id  = module.eks.node_security_group_id
  opensearch_instance_type    = var.opensearch_instance_type
  redis_node_type             = var.redis_node_type
}

module "networking" {
  source = "./modules/networking"

  aws_region                = var.aws_region
  vpc_id                    = module.vpc.vpc_id
  vpc_already_exists        = module.vpc.vpc_already_exists
  private_route_table_ids   = module.vpc.private_route_table_ids
  app_domain_name           = var.app_domain_name
}

module "ai" {
  source = "./modules/ai"

  project_name       = var.project_name
  environment        = var.environment
  aws_region         = var.aws_region
  bedrock_model_id   = var.bedrock_model_id
}

module "backend_irsa" {
  source = "./modules/backend_irsa"

  project_name           = var.project_name
  environment             = var.environment
  eks_oidc_provider_arn   = module.eks.oidc_provider_arn

  policy_arns = {
    dynamodb    = module.dynamodb.app_access_policy_arn
    sns         = module.sns.publish_policy_arn
    xray        = module.observability.xray_policy_arn
    messaging   = module.messaging.app_access_policy_arn
    search      = module.search.app_access_policy_arn
    bedrock     = module.ai.app_access_policy_arn
    kinesis     = module.analytics.kinesis_app_access_policy_arn
    ollama_cache = module.s3.ollama_model_cache_access_policy_arn
  }
}

module "scoring" {
  source = "./modules/scoring"

  project_name = var.project_name
  environment  = var.environment
  aws_region   = var.aws_region
  account_id   = data.aws_caller_identity.current.account_id

  accounts_table_name  = module.dynamodb.accounts_table_name
  accounts_table_arn   = module.dynamodb.accounts_table_arn
  transfers_table_name = module.dynamodb.transfers_table_name
  transfers_table_arn  = module.dynamodb.transfers_table_arn
  loans_table_name     = module.dynamodb.generic_tables["loans"].name
  loans_table_arn      = module.dynamodb.generic_tables["loans"].arn
  fraud_table_name     = module.dynamodb.generic_tables["fraud-detection"].name
  fraud_table_arn      = module.dynamodb.generic_tables["fraud-detection"].arn

  fraud_check_queue_arn = module.messaging.fraud_check_queue_arn
  fraud_check_queue_url = module.messaging.fraud_check_queue_url
}

module "security" {
  source = "./modules/security"

  project_name         = var.project_name
  environment           = var.environment
  rds_master_username   = module.rds.master_username
  rds_master_password   = module.rds.master_password
  rds_endpoint          = module.rds.cluster_endpoint
  rds_database_name     = module.rds.database_name
  enable_guardduty       = var.enable_guardduty
}

module "analytics" {
  source = "./modules/analytics"

  project_name                     = var.project_name
  environment                       = var.environment
  transaction_history_bucket_name   = module.s3.transaction_history_bucket_name
  transaction_history_bucket_arn    = module.s3.transaction_history_bucket_arn
}

module "monitoring" {
  source = "./modules/monitoring"

  grafana_admin_password = var.grafana_admin_password

  # Same reasoning as module.observability - must come strictly after the
  # ALB controller's helm release inside module.eks.
  depends_on = [module.eks]
}
