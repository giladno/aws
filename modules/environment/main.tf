# Database processing removed - now handled at global level

# Generate environment variables based on configuration
locals {
  # AWS Region environment variable (only for ECS services, not Lambda)
  region_env_vars = var.service_type != "lambda" && var.environment_config.region != null && var.environment_config.region != false ? [
    {
      name  = var.environment_config.region == true ? "AWS_REGION" : var.environment_config.region
      value = var.global_config.aws_region
    }
  ] : []

  # Node environment variable - for Lambda: string = NODE_ENV value, true = use project environment
  node_env_vars = var.environment_config.node != null && var.environment_config.node != false ? [
    {
      name  = "NODE_ENV"
      value = var.environment_config.node == true ? var.global_config.environment : var.environment_config.node
    }
  ] : []

  # S3 bucket environment variable
  s3_env_vars = var.environment_config.s3 != null && var.environment_config.s3 != false && var.global_config.s3_enabled ? [
    {
      name  = var.environment_config.s3 == true ? "S3_BUCKET" : var.environment_config.s3
      value = var.global_config.s3_bucket_name
    }
  ] : []

  # Custom environment variables
  custom_env_vars = [
    for key, value in var.environment_config.variables : {
      name  = key
      value = value
    }
  ]

  # Combine all environment variables (database removed)
  all_env_vars = concat(
    local.region_env_vars,
    local.node_env_vars,
    local.s3_env_vars,
    local.custom_env_vars
  )

  # Custom secrets from Secrets Manager
  custom_secrets = [
    for env_var_name, secret_ref in var.secrets_config : {
      name = env_var_name
      # Support both formats:
      # 1. "secret-name" -> whole secret  
      # 2. "secret-name:json-key" -> specific JSON key from secret
      # Use data source lookups to get correct ARNs with AWS-generated suffixes
      valueFrom = length(split(":", secret_ref)) > 1 ? (
        # Format: secret-name:json-key -> use data source ARN with json-key
        "${data.aws_secretsmanager_secret.custom_secrets[split(":", secret_ref)[0]].arn}:${split(":", secret_ref)[1]}::"
      ) : (
        # Format: secret-name -> use data source ARN (whole secret)
        data.aws_secretsmanager_secret.custom_secrets[secret_ref].arn
      )
    }
  ]

  # Combine all secrets (database removed)
  all_secrets = local.custom_secrets
}

# Data source for current AWS account
data "aws_caller_identity" "current" {}

# Extract unique secret names for data source creation
locals {
  secret_names = [
    for secret_ref in values(var.secrets_config) : 
    length(split(":", secret_ref)) > 1 ? split(":", secret_ref)[0] : secret_ref
  ]
}

# Data sources for custom secrets to get correct ARNs with AWS-generated suffixes
data "aws_secretsmanager_secret" "custom_secrets" {
  for_each = toset(local.secret_names)
  name = each.value
}