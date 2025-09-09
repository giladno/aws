# Lambda function outputs
output "function_arn" {
  value       = aws_lambda_function.main.arn
  description = "ARN of the Lambda function"
}

output "function_name" {
  value       = aws_lambda_function.main.function_name
  description = "Name of the Lambda function"
}

output "function_invoke_arn" {
  value       = aws_lambda_function.main.invoke_arn
  description = "Invoke ARN of the Lambda function"
}

output "log_group_name" {
  value       = aws_cloudwatch_log_group.lambda_logs.name
  description = "CloudWatch log group name"
}

# SQS Queue outputs (if SQS trigger is enabled)
output "sqs_queue_arn" {
  value       = var.function_config.triggers.sqs != null && var.function_config.triggers.sqs.enabled ? aws_sqs_queue.main[0].arn : null
  description = "SQS queue ARN (if SQS trigger is enabled)"
}

output "sqs_queue_url" {
  value       = var.function_config.triggers.sqs != null && var.function_config.triggers.sqs.enabled ? aws_sqs_queue.main[0].url : null
  description = "SQS queue URL (if SQS trigger is enabled)"
}

output "sqs_dlq_arn" {
  value       = var.function_config.triggers.sqs != null && var.function_config.triggers.sqs.enabled && var.function_config.triggers.sqs.queue_config.enable_dlq ? aws_sqs_queue.dlq[0].arn : null
  description = "SQS dead letter queue ARN (if enabled)"
}

# API Gateway outputs (if HTTP trigger is enabled)
output "api_gateway_url" {
  value       = var.function_config.triggers.http != null && var.function_config.triggers.http.enabled ? aws_apigatewayv2_stage.lambda_stage[0].invoke_url : null
  description = "API Gateway invoke URL (if HTTP trigger is enabled)"
}

output "api_gateway_domain_name" {
  value       = var.function_config.triggers.http != null && var.function_config.triggers.http.enabled && var.function_config.triggers.http.subdomain != null && var.config.dns_domain != null && var.config.subdomain_routing_allowed ? aws_apigatewayv2_domain_name.lambda_domain[0].domain_name : null
  description = "Custom domain name for API Gateway (if subdomain is configured and allowed)"
}

# CloudWatch Event Rule outputs (if schedule trigger is enabled)
output "schedule_rule_arn" {
  value       = var.function_config.triggers.schedule != null && var.function_config.triggers.schedule.enabled ? aws_cloudwatch_event_rule.schedule[0].arn : null
  description = "CloudWatch Event Rule ARN (if schedule trigger is enabled)"
}