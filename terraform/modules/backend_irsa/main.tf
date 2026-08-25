# ---------------------------------------------------------------------------
# IRSA role for the backend app -> DynamoDB/SNS/X-Ray/SQS/EventBridge/
# OpenSearch/Bedrock access (no static AWS keys needed).
#
# This is deliberately its OWN module rather than living inside modules/eks,
# because it needs the policy ARNs from dynamodb/sns/observability/
# messaging/search/ai - and those modules (observability in particular)
# need the EKS module's oidc_provider_arn as an input. Putting this role
# inside modules/eks would make eks depend on modules that depend on eks -
# a cycle. Living here (downstream of all of them) keeps the graph a DAG:
# eks -> {dynamodb, sns, observability, messaging, search, ai} -> backend_irsa.
# ---------------------------------------------------------------------------

module "backend_app_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name = "${var.project_name}-${var.environment}-backend-dynamodb"

  role_policy_arns = var.policy_arns

  oidc_providers = {
    main = {
      provider_arn               = var.eks_oidc_provider_arn
      namespace_service_accounts = ["${var.project_name}:backend-app"]
    }
  }
}
