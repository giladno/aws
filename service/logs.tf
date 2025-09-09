# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "service" {
  name              = "/aws/ecs/${var.config.name}/${var.service_name}"
  retention_in_days = var.service_config.log_retention_days
  
  # Encryption configuration (use global logging config)
  kms_key_id = (var.config.logging_kms != null && var.config.logging_kms != false && var.config.logging_kms != true) ? var.config.logging_kms : null

  tags = var.config.common_tags
}