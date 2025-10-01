# Data source to fetch database secret for Lambda functions (they need environment variables, not ECS secrets)
data "aws_secretsmanager_secret_version" "database_url_lambda" {
  count     = local.lambda_functions_needing_database && local.rds_enabled ? 1 : 0
  secret_id = aws_secretsmanager_secret.database_url[0].arn
}

# Parse database secret for Lambda environment variables
locals {
  # Clean the secret string by handling escaped characters properly (AWS may escape ! as \! or \\!)
  lambda_db_secret_string = local.lambda_functions_needing_database && local.rds_enabled ? replace(replace(data.aws_secretsmanager_secret_version.database_url_lambda[0].secret_string, "\\!", "!"), "\\\\!", "!") : ""
  lambda_db_secret_json   = local.lambda_functions_needing_database && local.rds_enabled ? jsondecode(local.lambda_db_secret_string) : {}

  # Generate enhanced environment variables for Lambda functions (including database)
  lambda_enhanced_environment_variables_with_secrets = {
    for function_name, function_config in local.lambda_functions_enabled :
    function_name => merge(
      # Use enhanced variables from unified processing (these now include database variables as placeholders)
      function_config.enhanced_environment_variables,
      # Add actual database secret value if database config exists
      local.rds_enabled && function_config.database_config != null && function_config.database_config != false ? {
        (function_config.database_env_var_name) = lookup(local.lambda_db_secret_json, "DATABASE_URL_ACTIVE", "")
      } : {}
    )
  }
}

# Lambda Functions - using the generic lambda module
module "lambda_functions" {
  source = "./lambda"

  for_each = local.lambda_functions_enabled

  function_name = each.key
  function_config = merge(each.value, {
    # Enhanced secrets are now part of the unified processing (each.value.enhanced_secrets)
    secrets = each.value.enhanced_secrets
    # Override environment variables with enhanced ones that include database
    environment = merge(each.value.environment, {
      variables = local.lambda_enhanced_environment_variables_with_secrets[each.key]
    })
  })
  global_config = var.lambda # Pass global lambda configuration

  # Configuration object with all necessary data
  config = {
    name                        = var.name
    aws_region                  = var.aws_region
    dns_domain                  = var.dns.domain != null ? var.dns.domain : null
    subdomain_routing_allowed   = local.subdomain_routing_allowed
    cloudfront_enabled          = local.s3_enabled && var.s3.public != null
    default_compatible_runtimes = local.lambda_compatible_runtimes
    tmp_directory               = var.tmp

    vpc = {
      id         = aws_vpc.main.id
      subnet_ids = aws_subnet.private[*].id
    }

    alb = local.alb_config.enabled ? {
      listener_arn      = aws_lb_listener.https[0].arn
      security_group_id = aws_security_group.alb[0].id
    } : null

    s3_bucket_name = local.s3_enabled ? aws_s3_bucket.main[0].id : null
    common_tags    = local.common_tags

    # RDS configuration for database access
    rds_enabled         = local.rds_enabled
    database_secret_arn = local.rds_enabled ? aws_secretsmanager_secret.database_url[0].arn : null

    # Pass shared Lambda security group ID (automatically managed)
    lambda_shared_security_group_id = local.lambda_needs_vpc ? aws_security_group.lambda_shared[0].id : null

    # EFS configuration for Lambda functions
    efs_enabled = var.efs.enabled
    efs_access_points = var.efs.enabled ? {
      for mount_name, access_point in aws_efs_access_point.mounts :
      mount_name => access_point.arn
    } : {}

    # Shared API Gateway domain (if created)
    api_gateway_domain_id = local.needs_api_gateway_domain ? aws_apigatewayv2_domain_name.shared_lambda_domain[0].id : null
    api_gateway_domain_enabled = local.needs_api_gateway_domain
  }

  # Pass the IAM role ARN
  # Custom role if function has custom permissions, otherwise shared role (enhanced with global permissions)
  lambda_role_arn = each.value.permissions != var.lambda.permissions ? aws_iam_role.lambda_custom_execution_role[each.key].arn : aws_iam_role.lambda_shared_execution_role[0].arn

  # Monitoring configuration
  monitoring_config = var.monitoring.enabled ? {
    enabled = true
    sns_topics = {
      critical_alerts_arn = aws_sns_topic.critical_alerts[0].arn
      warning_alerts_arn  = aws_sns_topic.warning_alerts[0].arn
    }
    lambda_alarms = {
      error_rate_threshold = var.monitoring.alarms.lambda_error_threshold
      duration_threshold   = var.monitoring.alarms.lambda_duration_threshold
      throttle_threshold   = var.monitoring.alarms.lambda_throttle_threshold
      evaluation_periods   = 2
    }
    } : {
    enabled = false
    sns_topics = {
      critical_alerts_arn = ""
      warning_alerts_arn  = ""
    }
    lambda_alarms = {
      error_rate_threshold = 5
      duration_threshold   = 10000
      throttle_threshold   = 5
      evaluation_periods   = 2
    }
  }
}

# S3 bucket notifications for Lambda S3 triggers
resource "aws_s3_bucket_notification" "lambda_triggers" {
  count = local.s3_enabled && length(local.lambda_s3_triggers) > 0 ? 1 : 0

  bucket = aws_s3_bucket.main[0].id

  dynamic "lambda_function" {
    for_each = local.lambda_s3_triggers
    content {
      lambda_function_arn = module.lambda_functions[lambda_function.key].function_arn
      events              = lambda_function.value.events
      filter_prefix       = lambda_function.value.filter_prefix
      filter_suffix       = lambda_function.value.filter_suffix
    }
  }

  depends_on = [module.lambda_functions]
}

# SQS Access Policies for Lambda Functions (created after SQS queues)
resource "aws_iam_role_policy" "lambda_sqs_access" {
  for_each = local.lambda_functions_needing_sqs

  name = "${var.name}-${each.key}-sqs-policy"
  role = each.value.permissions != var.lambda.permissions ? aws_iam_role.lambda_custom_execution_role[each.key].name : aws_iam_role.lambda_shared_execution_role[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:ChangeMessageVisibility"
        ]
        Resource = [
          module.lambda_functions[each.key].sqs_queue_arn
        ]
      }
    ]
  })

  depends_on = [module.lambda_functions]
}

# Local values for remaining Lambda processing (most moved to global locals)
locals {
  # Check if any Service needs database access (used only in lambda.tf)
  services_need_database = anytrue([
    for name, config in local.services_unified_enabled :
    config.environment.database != null && config.environment.database != false
  ])

  # Services that need database access (used only in lambda.tf)
  services_with_database = {
    for name, config in local.services_unified_enabled : name => config
    if config.environment.database != null && config.environment.database != false
  }

  # Lambda functions that need database access (used only in lambda.tf)
  lambdas_with_database = {
    for name, config in local.lambda_functions_enabled : name => config
    if config.environment.database != null && config.environment.database != false
  }
}

# Add Lambda monitoring alarms configuration to the existing monitoring variables
locals {
  lambda_enabled = length(var.lambda.functions) > 0
}

# Centralized Lambda Cleanup (Functions and Layers)
data "external" "lambda_cleanup" {
  count = length(local.lambda_functions_with_cleanup) > 0 || length(local.lambda_created_layers) > 0 ? 1 : 0

  program = ["bash", "-c", <<-EOT
    AWS_REGION="${var.aws_region}"

    echo "Starting Lambda cleanup..." >&2

    # Function version cleanup
    ${jsonencode(local.lambda_functions_with_cleanup) != "{}" ? join("\n", [
    for name, config in local.lambda_functions_with_cleanup :
    "FUNCTION_NAME=\"${var.name}-${name}\"; MAX_VERSIONS=\"${config.version_management.max_versions_to_keep}\"; echo \"Cleaning function $$FUNCTION_NAME...\" >&2; VERSIONS=$$(aws lambda list-versions-by-function --function-name \"$$FUNCTION_NAME\" --region \"$$AWS_REGION\" --query 'Versions[?Version!=\\`\\$$LATEST\\`].Version' --output text 2>/dev/null | tr '\\t' '\\n' | sort -V); VERSION_COUNT=$$(echo \"$$VERSIONS\" | wc -l); if [ \"$$VERSION_COUNT\" -gt \"$$MAX_VERSIONS\" ]; then VERSIONS_TO_DELETE=$$(echo \"$$VERSIONS\" | head -n $$((VERSION_COUNT - MAX_VERSIONS))); for version in $$VERSIONS_TO_DELETE; do echo \"Deleting function version $$version\" >&2; aws lambda delete-function --function-name \"$$FUNCTION_NAME\" --qualifier \"$$version\" --region \"$$AWS_REGION\" 2>/dev/null || true; done; fi"
    ]) : "echo 'No functions to clean' >&2"}

    # Layer version cleanup
    ${length(local.lambda_created_layers) > 0 ? join("\n", [
    for layer in local.lambda_created_layers :
    "LAYER_NAME=\"${layer.layer_name}\"; MAX_VERSIONS=\"${layer.max_versions}\"; echo \"Cleaning layer $$LAYER_NAME...\" >&2; VERSIONS=$$(aws lambda list-layer-versions --layer-name \"$$LAYER_NAME\" --region \"$$AWS_REGION\" --query 'LayerVersions[].Version' --output text 2>/dev/null | tr '\\t' '\\n' | sort -rn); VERSION_COUNT=$$(echo \"$$VERSIONS\" | wc -l); if [ \"$$VERSION_COUNT\" -gt \"$$MAX_VERSIONS\" ]; then VERSIONS_TO_DELETE=$$(echo \"$$VERSIONS\" | tail -n +$$((MAX_VERSIONS + 1))); for version in $$VERSIONS_TO_DELETE; do echo \"Deleting layer version $$version\" >&2; aws lambda delete-layer-version --layer-name \"$$LAYER_NAME\" --version-number \"$$version\" --region \"$$AWS_REGION\" 2>/dev/null || true; done; fi"
]) : "echo 'No layers to clean' >&2"}

    echo '{"functions_cleaned": "${length(local.lambda_functions_with_cleanup)}", "layers_cleaned": "${length(local.lambda_created_layers)}"}'
  EOT
]

depends_on = [module.lambda_functions]
}

# ALB Target Groups for Lambda HTTP triggers that need ALB routing
resource "aws_lb_target_group" "lambda_http" {
  for_each = local.alb_config.enabled ? local.lambda_needing_alb : {}

  name        = "${var.name}-${each.key}-lambda-tg"
  target_type = "lambda"

  tags = merge(local.common_tags, {
    Name = "${var.name}-${each.key}-lambda-tg"
  })
}

# ALB Target Group Attachments for Lambda
resource "aws_lb_target_group_attachment" "lambda_http" {
  for_each = local.alb_config.enabled ? local.lambda_needing_alb : {}

  target_group_arn = aws_lb_target_group.lambda_http[each.key].arn
  target_id        = module.lambda_functions[each.key].function_arn

  depends_on = [aws_lambda_permission.lambda_alb]
}

# ALB Listener Rules for Lambda HTTP triggers that need ALB routing
resource "aws_lb_listener_rule" "lambda_http" {
  for_each = local.alb_config.enabled ? local.lambda_needing_alb : {}

  listener_arn = aws_lb_listener.https[0].arn
  priority     = local.alb_lambda_rule_priorities[each.key] # Start from 1000 to avoid conflicts with services

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.lambda_http[each.key].arn
  }

  condition {
    path_pattern {
      values = [each.value.triggers.http.path_pattern != null ? each.value.triggers.http.path_pattern : "/${each.key}/*"]
    }
  }

  # Add HTTP method condition if methods are specified (ALB supports method filtering)
  dynamic "condition" {
    for_each = length(each.value.triggers.http.methods) > 0 ? [1] : []
    content {
      http_request_method {
        values = each.value.triggers.http.methods
      }
    }
  }
}

# Lambda permissions for ALB
resource "aws_lambda_permission" "lambda_alb" {
  for_each = local.alb_config.enabled ? local.lambda_needing_alb : {}

  statement_id  = "AllowExecutionFromALB"
  action        = "lambda:InvokeFunction"
  function_name = module.lambda_functions[each.key].function_name
  principal     = "elasticloadbalancing.amazonaws.com"
  source_arn    = aws_lb_target_group.lambda_http[each.key].arn
}

# Output Lambda information
output "lambda_functions" {
  value = {
    for name, lambda_config in local.lambda_functions_enabled : name => {
      function_arn       = module.lambda_functions[name].function_arn
      function_name      = module.lambda_functions[name].function_name
      log_group_name     = module.lambda_functions[name].log_group_name
      sqs_queue_url      = module.lambda_functions[name].sqs_queue_url
      api_gateway_url    = module.lambda_functions[name].api_gateway_url
      api_gateway_domain = module.lambda_functions[name].api_gateway_domain_name
      schedule_rule_arn  = module.lambda_functions[name].schedule_rule_arn
    }
  }
  description = "Lambda function information"
}
