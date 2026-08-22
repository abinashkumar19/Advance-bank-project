# ---------------------------------------------------------------------------
# Monitoring - Prometheus + Grafana, installed as the community
# kube-prometheus-stack chart (bundles Prometheus, Alertmanager, Grafana,
# and pre-built dashboards for node/pod metrics in one release).
#
# This is separate from CloudWatch Container Insights (modules/observability)
# - CloudWatch is the AWS-native option with zero extra pods to manage;
# Prometheus/Grafana is the option if you want PromQL, custom dashboards, or
# portability off AWS. Both can run side by side; nothing about this module
# depends on or conflicts with observability.tf.
#
# NOTE on ordering: like the CloudWatch addon, this creates Kubernetes
# Services, so the root module's call to this module must include
# `depends_on = [module.eks]` (comes strictly after the ALB controller's
# helm release, not just after the cluster exists) - see modules/eks.
# ---------------------------------------------------------------------------

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
  }
}

resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  version    = "62.7.0"

  # Keep this dev-sized: 1 Prometheus replica, no external storage class
  # requirements, small resource requests. Bump these for production.
  values = [
    yamlencode({
      grafana = {
        adminPassword = var.grafana_admin_password
        service = {
          type = "ClusterIP" # exposed via k8s/monitoring/grafana-ingress.yaml, not directly
        }
      }
      prometheus = {
        prometheusSpec = {
          retention = "7d"
          resources = {
            requests = { cpu = "250m", memory = "512Mi" }
          }
        }
      }
      alertmanager = {
        enabled = true
        alertmanagerSpec = {
          # Do NOT set `alertmanager.config` here - that would put the
          # Telegram bot token straight into this Helm release's values and
          # therefore into the Terraform state file. Instead this points
          # Alertmanager at a Secret named "alertmanager-config" that is
          # created directly with `kubectl` (never through Terraform/Helm)
          # in the deploy workflow, from the TELEGRAM_BOT_TOKEN /
          # TELEGRAM_CHAT_ID GitHub secrets - same pattern already used for
          # the SMTP/Groq app-secrets. See .github/workflows/deploy.yml,
          # "Sync alertmanager Telegram config" step, and
          # k8s/monitoring/alertmanager.yaml for the config template.
          #
          # Until that secret exists, the Alertmanager pod stays pending
          # (same behavior the app pods already have around app-secrets) -
          # harmless, it just starts as soon as the deploy job syncs it.
          configSecret = "alertmanager-config"
        }
      }
    })
  ]
}
