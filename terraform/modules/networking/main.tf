# ---------------------------------------------------------------------------
# Networking - ACM certificate (HTTPS on the ALB) + VPC gateway endpoints
# ---------------------------------------------------------------------------

resource "aws_acm_certificate" "app" {
  count             = var.app_domain_name != "" ? 1 : 0
  domain_name       = var.app_domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# Gateway endpoints (S3, DynamoDB) - no hourly cost.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = var.private_route_table_ids
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = var.private_route_table_ids
}

# Interface endpoints (ECR, CloudWatch Logs) intentionally left out by
# default - they bill hourly per-AZ on top of the NAT gateway you already
# have. Add them here if you want pods to reach ECR/CloudWatch without
# going through the NAT gateway at all.
