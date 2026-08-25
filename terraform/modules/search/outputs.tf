output "opensearch_endpoint" {
  value = aws_opensearch_domain.app.endpoint
}

output "opensearch_dashboards_endpoint" {
  value = aws_opensearch_domain.app.dashboard_endpoint
}

output "redis_endpoint" {
  value = aws_elasticache_cluster.app.cache_nodes[0].address
}

output "app_access_policy_arn" {
  value = aws_iam_policy.search_cache_app_access.arn
}
