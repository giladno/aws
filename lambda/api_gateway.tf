# API Gateway v2 (HTTP API) for Lambda HTTP triggers
resource "aws_apigatewayv2_api" "lambda_api" {
  count = var.function_config.triggers.http != null && var.function_config.triggers.http.enabled ? 1 : 0

  name          = "${var.config.name}-${var.function_name}-api"
  protocol_type = "HTTP"
  description   = "HTTP API for Lambda function ${var.function_name}"

  # API Gateway configuration
  route_selection_expression   = "$request.method $request.path"
  api_key_selection_expression = "$request.header.x-api-key"

  # CORS configuration (when CORS is enabled)
  dynamic "cors_configuration" {
    for_each = var.function_config.triggers.http.cors != null ? [1] : []
    content {
      # Handle different CORS input types
      allow_credentials = try(
        var.function_config.triggers.http.cors.allow_credentials,  # If object with allow_credentials
        false                                                       # Default
      )
      allow_headers = try(
        var.function_config.triggers.http.cors.allow_headers,                        # If object with allow_headers
        ["content-type", "x-amz-date", "authorization", "x-api-key", "x-amz-security-token"] # Default
      )
      allow_methods = try(
        var.function_config.triggers.http.cors.allow_methods,      # If object with allow_methods
        var.function_config.triggers.http.methods                  # Use function methods as default
      )
      allow_origins = try(
        var.function_config.triggers.http.cors.allow_origins,      # If object with allow_origins
        ["*"]                                                       # Default
      )
      expose_headers = try(
        var.function_config.triggers.http.cors.expose_headers,     # If object with expose_headers
        ["date", "keep-alive"]                                     # Default
      )
      max_age = try(
        var.function_config.triggers.http.cors.max_age,            # If object with max_age
        86400                                                       # Default (24 hours)
      )
    }
  }

  tags = var.config.common_tags
}

# API Gateway Stage
resource "aws_apigatewayv2_stage" "lambda_stage" {
  count = var.function_config.triggers.http != null && var.function_config.triggers.http.enabled ? 1 : 0

  api_id      = aws_apigatewayv2_api.lambda_api[0].id
  name        = "$default"
  auto_deploy = true

  # Access logging
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway[0].arn
    format = jsonencode({
      requestId        = "$context.requestId"
      requestTime      = "$context.requestTime"
      httpMethod       = "$context.httpMethod"
      routeKey         = "$context.routeKey"
      status           = "$context.status"
      error            = "$context.error.message"
      responseLength   = "$context.responseLength"
      integrationError = "$context.integrationErrorMessage"
    })
  }

  tags = var.config.common_tags
}

# CloudWatch Log Group for API Gateway
resource "aws_cloudwatch_log_group" "api_gateway" {
  count = var.function_config.triggers.http != null && var.function_config.triggers.http.enabled ? 1 : 0

  name              = "/aws/apigateway/${var.config.name}-${var.function_name}"
  retention_in_days = 7 # Default retention
  
  # Encryption configuration
  kms_key_id = (var.function_config.kms != null && var.function_config.kms != false && var.function_config.kms != true) ? var.function_config.kms : null

  tags = var.config.common_tags
}

# API Gateway Integration
resource "aws_apigatewayv2_integration" "lambda_integration" {
  count = var.function_config.triggers.http != null && var.function_config.triggers.http.enabled ? 1 : 0

  api_id             = aws_apigatewayv2_api.lambda_api[0].id
  integration_type   = "AWS_PROXY"
  integration_method = "POST"
  integration_uri    = aws_lambda_function.main.invoke_arn

  payload_format_version = "2.0"
  timeout_milliseconds   = local.effective_timeout * 1000 # Convert to milliseconds
}

# API Gateway Routes - exact path (e.g., GET /hello)
resource "aws_apigatewayv2_route" "lambda_route_exact" {
  for_each = var.function_config.triggers.http != null && var.function_config.triggers.http.enabled && var.function_config.triggers.http.path_pattern != null ? toset(var.function_config.triggers.http.methods) : toset([])

  api_id    = aws_apigatewayv2_api.lambda_api[0].id
  route_key = "${each.value} ${trimsuffix(var.function_config.triggers.http.path_pattern, "/")}"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration[0].id}"

  # Authorization
  authorization_type = var.function_config.triggers.http.authorization
}

# API Gateway Routes - proxy path (e.g., GET /hello/{proxy+}) - only when catch_all_enabled
resource "aws_apigatewayv2_route" "lambda_route_proxy" {
  for_each = var.function_config.triggers.http != null && var.function_config.triggers.http.enabled && var.function_config.triggers.http.catch_all_enabled && var.function_config.triggers.http.path_pattern != null ? toset(var.function_config.triggers.http.methods) : toset([])

  api_id    = aws_apigatewayv2_api.lambda_api[0].id
  route_key = "${each.value} ${trimsuffix(var.function_config.triggers.http.path_pattern, "/")}/{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration[0].id}"

  # Authorization
  authorization_type = var.function_config.triggers.http.authorization
}



# Lambda permission for API Gateway
resource "aws_lambda_permission" "allow_api_gateway" {
  count = var.function_config.triggers.http != null && var.function_config.triggers.http.enabled ? 1 : 0

  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.main.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.lambda_api[0].execution_arn}/*"
}

# Custom domain for CloudFront integration (main domain, no Route53)
resource "aws_apigatewayv2_domain_name" "lambda_domain_cloudfront" {
  count = var.function_config.triggers.http != null && var.function_config.triggers.http.enabled && var.config.dns_domain != null && var.config.cloudfront_enabled && var.function_config.triggers.http.path_pattern != null && !try(var.function_config.triggers.http.alb, false) ? 1 : 0

  domain_name = var.config.dns_domain

  domain_name_configuration {
    certificate_arn = data.aws_acm_certificate.main_domain[0].arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }

  tags = var.config.common_tags
}

# Custom domain for subdomain routing (with Route53)
resource "aws_apigatewayv2_domain_name" "lambda_domain" {
  count = var.function_config.triggers.http != null && var.function_config.triggers.http.enabled && var.config.dns_domain != null && var.config.subdomain_routing_allowed && var.function_config.triggers.http.subdomain != null ? 1 : 0

  domain_name = "${var.function_config.triggers.http.subdomain}.${var.config.dns_domain}"

  domain_name_configuration {
    certificate_arn = data.aws_acm_certificate.main[0].arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2" # Note: API Gateway v2 max supported version (TLS 1.3 not available)
  }

  tags = var.config.common_tags
}

# API Gateway domain mapping for CloudFront (main domain)
resource "aws_apigatewayv2_api_mapping" "lambda_mapping_cloudfront" {
  count = var.function_config.triggers.http != null && var.function_config.triggers.http.enabled && var.config.dns_domain != null && var.config.cloudfront_enabled && var.function_config.triggers.http.path_pattern != null && !try(var.function_config.triggers.http.alb, false) ? 1 : 0

  api_id          = aws_apigatewayv2_api.lambda_api[0].id
  domain_name     = aws_apigatewayv2_domain_name.lambda_domain_cloudfront[0].id
  stage           = aws_apigatewayv2_stage.lambda_stage[0].id
  api_mapping_key = trimprefix(var.function_config.triggers.http.path_pattern, "/")  # Use path pattern as mapping key
}

# API Gateway domain mapping for subdomain routing
resource "aws_apigatewayv2_api_mapping" "lambda_mapping" {
  count = var.function_config.triggers.http != null && var.function_config.triggers.http.enabled && var.config.dns_domain != null && var.config.subdomain_routing_allowed && var.function_config.triggers.http.subdomain != null ? 1 : 0

  api_id          = aws_apigatewayv2_api.lambda_api[0].id
  domain_name     = aws_apigatewayv2_domain_name.lambda_domain[0].id
  stage           = aws_apigatewayv2_stage.lambda_stage[0].id
  api_mapping_key = null  # No path mapping needed - $default stage handles requests without stage prefix
}

# Data source for existing ACM certificate (main domain)
data "aws_acm_certificate" "main_domain" {
  count = var.function_config.triggers.http != null && var.function_config.triggers.http.enabled && var.config.dns_domain != null && var.config.cloudfront_enabled && var.function_config.triggers.http.path_pattern != null && !try(var.function_config.triggers.http.alb, false) ? 1 : 0

  # Extract root domain from the DNS domain (e.g., app-dev.askteddi.com -> askteddi.com)
  domain   = length(split(".", var.config.dns_domain)) >= 2 ? join(".", slice(split(".", var.config.dns_domain), length(split(".", var.config.dns_domain)) - 2, length(split(".", var.config.dns_domain)))) : var.config.dns_domain
  statuses = ["ISSUED"]
}

# Data source for existing ACM certificate (subdomain wildcard)
data "aws_acm_certificate" "main" {
  count = var.function_config.triggers.http != null && var.function_config.triggers.http.enabled && var.config.dns_domain != null && var.config.subdomain_routing_allowed && var.function_config.triggers.http.subdomain != null ? 1 : 0

  # Extract root domain and look for its certificate (which includes wildcard as SAN)
  domain   = length(split(".", var.config.dns_domain)) >= 2 ? join(".", slice(split(".", var.config.dns_domain), length(split(".", var.config.dns_domain)) - 2, length(split(".", var.config.dns_domain)))) : var.config.dns_domain
  statuses = ["ISSUED"]
}

# Route53 zone lookup for API Gateway custom domain
data "aws_route53_zone" "main" {
  count = var.function_config.triggers.http != null && var.function_config.triggers.http.enabled && var.config.dns_domain != null && var.config.subdomain_routing_allowed && var.function_config.triggers.http.subdomain != null ? 1 : 0

  name = var.config.dns_domain  # Base domain for subdomain routing
  private_zone = false
}

resource "aws_route53_record" "lambda_domain" {
  count = var.function_config.triggers.http != null && var.function_config.triggers.http.enabled && var.config.dns_domain != null && var.config.subdomain_routing_allowed && var.function_config.triggers.http.subdomain != null ? 1 : 0

  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = "${var.function_config.triggers.http.subdomain}.${var.config.dns_domain}"
  type    = "A"

  alias {
    name                   = aws_apigatewayv2_domain_name.lambda_domain[0].domain_name_configuration[0].target_domain_name
    zone_id                = aws_apigatewayv2_domain_name.lambda_domain[0].domain_name_configuration[0].hosted_zone_id
    evaluate_target_health = false
  }
}