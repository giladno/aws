# Shared API Gateway domain for Lambda functions with CloudFront
# This domain is created once and shared by all Lambda functions that use path-based routing

# Shared API Gateway domain for CloudFront integration
resource "aws_apigatewayv2_domain_name" "shared_lambda_domain" {
  count = local.needs_api_gateway_domain ? 1 : 0

  domain_name = var.dns.domain

  domain_name_configuration {
    certificate_arn = data.aws_acm_certificate.main[0].arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }

  tags = merge(
    local.common_tags,
    {
      Name        = "${var.name}-api-gateway-domain"
      Description = "Shared API Gateway domain for Lambda functions"
    }
  )
}

# Output the domain name and configuration for Lambda functions to use
output "api_gateway_domain_id" {
  description = "ID of the shared API Gateway domain"
  value       = local.needs_api_gateway_domain ? aws_apigatewayv2_domain_name.shared_lambda_domain[0].id : null
}

output "api_gateway_domain_name" {
  description = "Name of the shared API Gateway domain"
  value       = local.needs_api_gateway_domain ? aws_apigatewayv2_domain_name.shared_lambda_domain[0].domain_name : null
}

output "api_gateway_domain_target" {
  description = "Target domain name for the API Gateway domain"
  value       = local.needs_api_gateway_domain ? aws_apigatewayv2_domain_name.shared_lambda_domain[0].domain_name_configuration[0].target_domain_name : null
}

output "api_gateway_domain_zone_id" {
  description = "Hosted zone ID for the API Gateway domain"
  value       = local.needs_api_gateway_domain ? aws_apigatewayv2_domain_name.shared_lambda_domain[0].domain_name_configuration[0].hosted_zone_id : null
}