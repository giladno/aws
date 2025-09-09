# Environment variables output
output "environment_variables" {
  description = "List of environment variables for ECS/Lambda"
  value       = local.all_env_vars
}

# Secrets output
output "secrets" {
  description = "List of secrets for ECS/Lambda"
  value       = local.all_secrets
}

# Secret ARNs output (for IAM policy generation)
output "secret_arns" {
  description = "Map of secret names to their actual ARNs"
  value = {
    for secret_name, secret_data in data.aws_secretsmanager_secret.custom_secrets :
    secret_name => secret_data.arn
  }
}

