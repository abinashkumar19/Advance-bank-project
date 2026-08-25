output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value = module.eks.cluster_certificate_authority_data
}

output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

output "node_security_group_id" {
  value = module.eks.node_security_group_id
}

# Downstream modules (observability, etc.) that create Kubernetes Services
# must depend on this - it only becomes true once the ALB controller's
# webhook actually has a pod behind it, see the note in observability.tf.
output "alb_controller_ready" {
  value = helm_release.alb_controller.status
}
