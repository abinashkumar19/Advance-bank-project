variable "grafana_admin_password" {
  description = "Grafana admin password. Defaults to \"admin\" for easy dev-environment access - if you expose Grafana beyond a local port-forward or a locked-down dev ALB, override this (e.g. via TF_VAR_grafana_admin_password) rather than leaving the default."
  type        = string
  default     = "admin"
  sensitive   = true
}
