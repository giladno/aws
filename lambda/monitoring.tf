# Lambda Error Rate Alarm
resource "aws_cloudwatch_metric_alarm" "lambda_error_rate" {
  count = var.function_config.monitoring && var.monitoring_config.enabled ? 1 : 0

  alarm_name          = "${var.config.name}-${var.function_name}-error-rate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.monitoring_config.lambda_alarms.evaluation_periods
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = var.monitoring_config.lambda_alarms.error_rate_threshold
  alarm_description   = "Lambda function ${var.function_name} error rate is too high"
  alarm_actions       = [var.monitoring_config.sns_topics.critical_alerts_arn]
  ok_actions          = [var.monitoring_config.sns_topics.critical_alerts_arn]

  dimensions = {
    FunctionName = aws_lambda_function.main.function_name
  }

  treat_missing_data = "notBreaching"
  tags               = var.config.common_tags
}

# Lambda Duration Alarm
resource "aws_cloudwatch_metric_alarm" "lambda_duration" {
  count = var.function_config.monitoring && var.monitoring_config.enabled ? 1 : 0

  alarm_name          = "${var.config.name}-${var.function_name}-duration"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.monitoring_config.lambda_alarms.evaluation_periods
  metric_name         = "Duration"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Average"
  threshold           = var.monitoring_config.lambda_alarms.duration_threshold
  alarm_description   = "Lambda function ${var.function_name} duration is too high"
  alarm_actions       = [var.monitoring_config.sns_topics.warning_alerts_arn]
  ok_actions          = [var.monitoring_config.sns_topics.warning_alerts_arn]

  dimensions = {
    FunctionName = aws_lambda_function.main.function_name
  }

  treat_missing_data = "notBreaching"
  tags               = var.config.common_tags
}

# Lambda Throttle Alarm
resource "aws_cloudwatch_metric_alarm" "lambda_throttles" {
  count = var.function_config.monitoring && var.monitoring_config.enabled ? 1 : 0

  alarm_name          = "${var.config.name}-${var.function_name}-throttles"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.monitoring_config.lambda_alarms.evaluation_periods
  metric_name         = "Throttles"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = var.monitoring_config.lambda_alarms.throttle_threshold
  alarm_description   = "Lambda function ${var.function_name} is being throttled"
  alarm_actions       = [var.monitoring_config.sns_topics.critical_alerts_arn]
  ok_actions          = [var.monitoring_config.sns_topics.critical_alerts_arn]

  dimensions = {
    FunctionName = aws_lambda_function.main.function_name
  }

  treat_missing_data = "notBreaching"
  tags               = var.config.common_tags
}

# API Gateway 4XX Errors (if HTTP trigger is enabled)
resource "aws_cloudwatch_metric_alarm" "api_gateway_4xx" {
  count = var.function_config.monitoring && var.monitoring_config.enabled && var.function_config.triggers.http != null && var.function_config.triggers.http.enabled ? 1 : 0

  alarm_name          = "${var.config.name}-${var.function_name}-api-4xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "4XXError"
  namespace           = "AWS/ApiGatewayV2"
  period              = 300
  statistic           = "Sum"
  threshold           = 10
  alarm_description   = "API Gateway for ${var.function_name} has high 4XX error rate"
  alarm_actions       = [var.monitoring_config.sns_topics.warning_alerts_arn]

  dimensions = {
    ApiId = aws_apigatewayv2_api.lambda_api[0].id
  }

  treat_missing_data = "notBreaching"
  tags               = var.config.common_tags
}

# API Gateway 5XX Errors (if HTTP trigger is enabled)
resource "aws_cloudwatch_metric_alarm" "api_gateway_5xx" {
  count = var.function_config.monitoring && var.monitoring_config.enabled && var.function_config.triggers.http != null && var.function_config.triggers.http.enabled ? 1 : 0

  alarm_name          = "${var.config.name}-${var.function_name}-api-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "5XXError"
  namespace           = "AWS/ApiGatewayV2"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "API Gateway for ${var.function_name} has high 5XX error rate"
  alarm_actions       = [var.monitoring_config.sns_topics.critical_alerts_arn]

  dimensions = {
    ApiId = aws_apigatewayv2_api.lambda_api[0].id
  }

  treat_missing_data = "notBreaching"
  tags               = var.config.common_tags
}