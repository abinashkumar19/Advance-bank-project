# ---------------------------------------------------------------------------
# Data & Search - OpenSearch (full-text search) + ElastiCache Redis (caching)
# Sized small/dev-tier on purpose - bump the instance type vars for
# production traffic.
# ---------------------------------------------------------------------------

# OpenSearch domains joined to a VPC (like this one) genuinely require this
# account-wide service-linked role to already exist BEFORE domain creation -
# AWS does not reliably auto-create it in time for a VPC-joined domain, so
# skipping this step (an earlier version of this file did, based on a wrong
# assumption) breaks CreateDomain with: "you must enable a service-linked
# role to give Amazon OpenSearch Service permissions to access your VPC."
#
# But it's also an account-wide *singleton* - only one is ever allowed per
# AWS account, so a plain `aws_iam_service_linked_role` resource errors
# "already exists" the moment this account has used OpenSearch anywhere
# before (a previous apply, a console experiment, another stack - doesn't
# matter). Terraform has no built-in "create if not exists" for this
# resource type, so this uses the AWS CLI directly via local-exec, which
# *is* naturally idempotent (`|| true` swallows the harmless
# already-exists error either way) - safe to re-run apply indefinitely,
# unlike the resource-based approach.
resource "null_resource" "opensearch_service_linked_role" {
  provisioner "local-exec" {
    command = "aws iam create-service-linked-role --aws-service-name opensearchservice.amazonaws.com || true"
  }

  # IAM is eventually consistent - give the role a moment to propagate
  # before the domain creation call below tries to use it.
  provisioner "local-exec" {
    command = "sleep 15"
  }
}

resource "aws_security_group" "search_and_cache" {
  name        = "${var.project_name}-${var.environment}-search-cache-sg"
  description = "Allow OpenSearch (443) and Redis (6379) from EKS pods"
  vpc_id      = var.vpc_id

  ingress {
    description     = "HTTPS from EKS nodes/pods"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [var.eks_node_security_group_id]
  }

  ingress {
    description     = "Redis from EKS nodes/pods"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [var.eks_node_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_opensearch_domain" "app" {
  domain_name    = "${var.project_name}-${var.environment}-search"
  engine_version = "OpenSearch_2.15"

  cluster_config {
    instance_type  = var.opensearch_instance_type
    instance_count = 1
  }

  ebs_options {
    ebs_enabled = true
    volume_size = 20
    volume_type = "gp3"
  }

  vpc_options {
    subnet_ids         = [var.private_subnet_ids[0]]
    security_group_ids = [aws_security_group.search_and_cache.id]
  }

  encrypt_at_rest {
    enabled = true
  }

  node_to_node_encryption {
    enabled = true
  }

  domain_endpoint_options {
    enforce_https = true
  }

  advanced_security_options {
    enabled                        = true
    internal_user_database_enabled = true
    master_user_options {
      master_user_name     = "appadmin"
      master_user_password = random_password.opensearch_master.result
    }
  }

  depends_on = [null_resource.opensearch_service_linked_role]
}

resource "random_password" "opensearch_master" {
  length      = 20
  special     = true
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
}

resource "aws_elasticache_subnet_group" "app" {
  name       = "${var.project_name}-${var.environment}-redis"
  subnet_ids = var.private_subnet_ids
}

resource "aws_elasticache_cluster" "app" {
  cluster_id           = "${var.project_name}-${var.environment}-redis"
  engine               = "redis"
  engine_version       = "7.1"
  node_type            = var.redis_node_type
  num_cache_nodes      = 1
  parameter_group_name = "default.redis7"
  port                 = 6379

  subnet_group_name  = aws_elasticache_subnet_group.app.name
  security_group_ids = [aws_security_group.search_and_cache.id]
}

resource "aws_iam_policy" "search_cache_app_access" {
  name        = "${var.project_name}-${var.environment}-search-cache-access"
  description = "Allows backend pods to query OpenSearch (network access is via SG; this covers the AWS-managed connection check)"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "OpenSearchHttp"
        Effect   = "Allow"
        Action   = ["es:ESHttpGet", "es:ESHttpPost", "es:ESHttpPut", "es:ESHttpDelete"]
        Resource = "${aws_opensearch_domain.app.arn}/*"
      }
    ]
  })
}
