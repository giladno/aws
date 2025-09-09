# Local values for service references
locals {
  ecs_service = var.service_config.force_new_deployment ? aws_ecs_service.service_auto_deploy[0] : aws_ecs_service.service_manual_deploy[0]
}

# Service outputs
output "target_group_arn" {
  value       = length(aws_lb_target_group.service) > 0 ? aws_lb_target_group.service[0].arn : null
  description = "ALB target group ARN for this service (null if not a public service)"
}

output "target_group_arn_suffix" {
  value       = length(aws_lb_target_group.service) > 0 ? aws_lb_target_group.service[0].arn_suffix : null
  description = "ALB target group ARN suffix for CloudWatch metrics (null if not a public service)"
}

output "security_group_id" {
  value       = aws_security_group.service.id
  description = "Security group ID for this service"
}

output "log_group_name" {
  value       = aws_cloudwatch_log_group.service.name
  description = "CloudWatch log group name for this service"
}

output "ecs_service_name" {
  value       = local.ecs_service.name
  description = "ECS service name"
}

output "autoscaling_target_resource_id" {
  value       = aws_appautoscaling_target.service.resource_id
  description = "Auto scaling target resource ID"
}

# Debug outputs for service module
output "debug_05_service_module_secrets" {
  value = var.secrets
  description = "Secrets received by service module"
}