# ---------------------------------------------------------------------------
# Observability - CloudWatch Container Insights + X-Ray distributed tracing
#
# NOTE on ordering: this addon creates its own Kubernetes Services, which
# get intercepted by the ALB controller's mutating webhook. If the
# controller isn't up yet, the webhook has no pod behind it and every
# Service create/update in the cluster fails. The root module's call to
# this module MUST include `depends_on = [module.eks]` so it comes
# strictly after the ALB controller's helm release, not just after the
# cluster exists.
# ---------------------------------------------------------------------------

resource "aws_eks_addon" "cloudwatch_observability" {
  cluster_name                = var.eks_cluster_name
  addon_name                  = "amazon-cloudwatch-observability"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/${var.project_name}/${var.environment}/app"
  retention_in_days = 14
}

resource "aws_iam_policy" "xray_write_access" {
  name        = "${var.project_name}-${var.environment}-xray-write"
  description = "Allows backend pods to send trace segments to X-Ray"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "XRayWrite"
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords",
          "xray:GetSamplingRules",
          "xray:GetSamplingTargets"
        ]
        Resource = "*"
      }
    ]
  })
}

# X-Ray daemon runs as a sidecar/daemonset in-cluster (see
# k8s/observability/xray-daemonset.yaml) and forwards traces using this role.
module "xray_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name = "${var.project_name}-${var.environment}-xray-daemon"

  role_policy_arns = {
    xray = aws_iam_policy.xray_write_access.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = var.eks_oidc_provider_arn
      namespace_service_accounts = ["${var.project_name}:xray-daemon"]
    }
  }
}
