output "grafana_admin_password" {
  value     = var.grafana_admin_password
  sensitive = true
}

output "namespace" {
  value = kubernetes_namespace.monitoring.metadata[0].name
}
