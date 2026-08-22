output "acm_certificate_validation_records" {
  description = "Add these CNAME records at your DNS provider to validate the cert, then reference the cert ARN in k8s/ingress.yaml"
  value = var.app_domain_name != "" ? {
    for dvo in aws_acm_certificate.app[0].domain_validation_options :
    dvo.domain_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  } : {}
}

output "acm_certificate_arn" {
  value = var.app_domain_name != "" ? aws_acm_certificate.app[0].arn : null
}
