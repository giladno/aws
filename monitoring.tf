# SNS Topic for Critical Alerts
resource "aws_sns_topic" "critical_alerts" {
  count = local.monitoring_config.enabled ? 1 : 0

  name = "${var.name}-critical-alerts"

  tags = local.common_tags
}

# SNS Topic for Warning Alerts
resource "aws_sns_topic" "warning_alerts" {
  count = local.monitoring_config.enabled ? 1 : 0

  name = "${var.name}-warning-alerts"

  tags = local.common_tags
}

# SNS Topic Subscriptions for Critical Alerts
resource "aws_sns_topic_subscription" "critical_alerts_email" {
  for_each = var.monitoring.enabled && var.monitoring.sns_notifications.critical_alerts_email != null ? toset(
    flatten([var.monitoring.sns_notifications.critical_alerts_email])
  ) : toset([])

  topic_arn = aws_sns_topic.critical_alerts[0].arn
  protocol  = "email"
  endpoint  = each.value
}

# SNS Topic Subscriptions for Warning Alerts
resource "aws_sns_topic_subscription" "warning_alerts_email" {
  for_each = var.monitoring.enabled && var.monitoring.sns_notifications.warning_alerts_email != null ? toset(
    flatten([var.monitoring.sns_notifications.warning_alerts_email])
  ) : toset([])

  topic_arn = aws_sns_topic.warning_alerts[0].arn
  protocol  = "email"
  endpoint  = each.value
}

# CloudWatch Dashboard
resource "aws_cloudwatch_dashboard" "main" {
  count = local.monitoring_config.dashboard_enabled ? 1 : 0

  dashboard_name = "${var.name}-dashboard"

  dashboard_body = jsonencode({
    widgets = flatten([
      # Instructions widget
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 2
        properties = {
          markdown = <<-EOT
## How to Filter Logs
**To filter logs:** Click on any log widget below → The query editor will open → Add filter line: `| filter component = "hello"` → Click "Run query"

**Available Lambda functions:** ${join(", ", [for l in keys(local.lambda_functions_enabled) : "`${l}`"])}
**Available Services:** ${join(", ", [for s in keys(local.services_unified_enabled) : "`${s}`"])}
EOT
        }
      },

      # ALB Metrics Widget (only when ALB is enabled)
      local.alb_enabled ? [
        {
          type   = "metric"
          x      = 0
          y      = 2
          width  = 12
          height = 6

          properties = {
            metrics = [
              ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.main[0].arn_suffix],
              [".", "TargetResponseTime", ".", "."],
              [".", "HTTPCode_Target_2XX_Count", ".", "."],
              [".", "HTTPCode_Target_4XX_Count", ".", "."],
              [".", "HTTPCode_Target_5XX_Count", ".", "."]
            ]
            view    = "timeSeries"
            stacked = false
            region  = var.aws_region
            title   = "Application Load Balancer Metrics"
            period  = 300
          }
        }
      ] : [],

      # RDS Metrics Widget (only when RDS is enabled)
      local.rds_enabled && local.is_aurora ? [
        {
          type   = "metric"
          x      = 0
          y      = local.alb_enabled ? 6 : 0
          width  = 12
          height = 6

          properties = {
            metrics = [
              ["AWS/RDS", "CPUUtilization", "DBClusterIdentifier", aws_rds_cluster.main[0].cluster_identifier],
              [".", "DatabaseConnections", ".", "."],
              [".", "ReadLatency", ".", "."],
              [".", "WriteLatency", ".", "."]
            ]
            view    = "timeSeries"
            stacked = false
            region  = var.aws_region
            title   = "Aurora Cluster Metrics"
            period  = 300
          }
        }
      ] : [],

      # ECS Metrics Widget (only when ECS is enabled)
      local.fargate_enabled ? [
        {
          type   = "metric"
          x      = 0
          y      = (local.alb_enabled ? 6 : 0) + (local.rds_enabled && local.is_aurora ? 6 : 0)
          width  = 12
          height = 6

          properties = {
            metrics = [
              ["AWS/ECS", "CPUUtilization", "ServiceName", "${var.name}-*", "ClusterName", aws_ecs_cluster.main.name],
              [".", "MemoryUtilization", ".", ".", ".", "."]
            ]
            view    = "timeSeries"
            stacked = false
            region  = var.aws_region
            title   = "ECS Service Metrics"
            period  = 300
          }
        }
      ] : [],

      # CloudFront Metrics Widget (only when CloudFront is enabled)
      local.s3_enabled && var.s3.public != null ? [
        {
          type   = "metric"
          x      = 0
          y      = (local.alb_enabled ? 6 : 0) + (local.rds_enabled && local.is_aurora ? 6 : 0) + (local.fargate_enabled ? 6 : 0)
          width  = 12
          height = 6

          properties = {
            metrics = [
              ["AWS/CloudFront", "Requests", "DistributionId", aws_cloudfront_distribution.main[0].id],
              [".", "BytesDownloaded", ".", "."],
              [".", "4xxErrorRate", ".", "."],
              [".", "5xxErrorRate", ".", "."]
            ]
            view    = "timeSeries"
            stacked = false
            region  = var.aws_region
            title   = "CloudFront Metrics"
            period  = 300
          }
        }
      ] : [],

      # Combined log widgets for all services and lambdas
      length(local.services_unified_enabled) > 0 || length(local.lambda_functions_enabled) > 0 ? [
        {
          type   = "log"
          x      = 0
          y      = 2 + (local.alb_enabled ? 6 : 0) + (local.rds_enabled && local.is_aurora ? 6 : 0) + (local.fargate_enabled ? 6 : 0) + (local.s3_enabled && var.s3.public != null ? 6 : 0)
          width  = 24
          height = 6

          properties = {
            query = <<-EOQ
SOURCE ${join(" | SOURCE ", concat(
            [for service, config in local.services_unified_enabled : "'/aws/ecs/${var.name}/${service}'"],
            [for lambda_name, lambda_config in local.lambda_functions_enabled : "'/aws/lambda/${var.name}-${lambda_name}'"]
      ))}
| fields @timestamp, @message, @logStream, @log
| parse @log "*/aws/*/*/*" as prefix, service_type, project, component
| display @timestamp, component, service_type, @message
| sort @timestamp desc
| limit 100
EOQ
      region = var.aws_region
      title  = "All Application Logs (Services & Lambda Functions)"
      view   = "table"
      }
    },
    {
      type   = "log"
      x      = 0
      y      = 2 + (local.alb_enabled ? 6 : 0) + (local.rds_enabled && local.is_aurora ? 6 : 0) + (local.fargate_enabled ? 6 : 0) + (local.s3_enabled && var.s3.public != null ? 6 : 0) + 6
      width  = 24
      height = 6

      properties = {
        query = <<-EOQ
SOURCE ${join(" | SOURCE ", concat(
        [for service, config in local.services_unified_enabled : "'/aws/ecs/${var.name}/${service}'"],
        [for lambda_name, lambda_config in local.lambda_functions_enabled : "'/aws/lambda/${var.name}-${lambda_name}'"]
    ))}
| fields @timestamp, @message, @logStream, @log
| filter @message like /ERROR/ or @message like /Exception/ or @message like /FATAL/ or @message like /failed/
| parse @log "*/aws/*/*/*" as prefix, service_type, project, component
| display @timestamp, component, service_type, @message
| sort @timestamp desc
| limit 50
EOQ
    region = var.aws_region
    title  = "Error Logs (All Services & Lambda Functions)"
  }
}
] : [],

# Individual Lambda function widgets
[for lambda_name, lambda_config in local.lambda_functions_enabled : {
  type   = "log"
  x      = 0
  y      = (local.alb_enabled ? 6 : 0) + (local.rds_enabled && local.is_aurora ? 6 : 0) + (local.fargate_enabled ? 6 : 0) + (local.s3_enabled && var.s3.public != null ? 6 : 0) + 12 + (index(keys(local.lambda_functions_enabled), lambda_name) * 6)
  width  = 12
  height = 6

  properties = {
    query  = <<-EOQ
SOURCE '/aws/lambda/${var.name}-${lambda_name}'
| fields @timestamp, @message
| sort @timestamp desc
| limit 200
EOQ
    region = var.aws_region
    title  = "Lambda: ${lambda_name}"
    view   = "table"
  }
}],

# Individual service widgets
[for service_name, service_config in local.services_unified_enabled : {
  type   = "log"
  x      = 12
  y      = (local.alb_enabled ? 6 : 0) + (local.rds_enabled && local.is_aurora ? 6 : 0) + (local.fargate_enabled ? 6 : 0) + (local.s3_enabled && var.s3.public != null ? 6 : 0) + 12 + (index(keys(local.services_unified_enabled), service_name) * 6)
  width  = 12
  height = 6

  properties = {
    query  = <<-EOQ
SOURCE '/aws/ecs/${var.name}/${service_name}'
| fields @timestamp, @message
| sort @timestamp desc
| limit 200
EOQ
    region = var.aws_region
    title  = "Service: ${service_name}"
    view   = "table"
  }
}]
])
})
}

# Aurora Cluster CPU Utilization Alarm
resource "aws_cloudwatch_metric_alarm" "aurora_cpu_high" {
  count = local.monitoring_config.aurora_monitoring_enabled ? 1 : 0

  alarm_name          = "${var.name}-aurora-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.monitoring.alarms.aurora_cpu_evaluation_periods
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = var.monitoring.alarms.aurora_cpu_period
  statistic           = "Average"
  threshold           = var.monitoring.alarms.aurora_cpu_threshold
  alarm_description   = "This metric monitors Aurora cluster CPU utilization"
  alarm_actions       = [aws_sns_topic.warning_alerts[0].arn]
  ok_actions          = [aws_sns_topic.warning_alerts[0].arn]

  dimensions = {
    DBClusterIdentifier = aws_rds_cluster.main[0].cluster_identifier
  }

  tags = local.common_tags
}

# Aurora Database Connections Alarm
resource "aws_cloudwatch_metric_alarm" "aurora_connections_high" {
  count = local.monitoring_config.aurora_monitoring_enabled ? 1 : 0

  alarm_name          = "${var.name}-aurora-connections-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.monitoring.alarms.aurora_cpu_evaluation_periods
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = var.monitoring.alarms.aurora_cpu_period
  statistic           = "Average"
  threshold           = var.monitoring.alarms.aurora_connections_threshold
  alarm_description   = "This metric monitors Aurora database connections"
  alarm_actions       = [aws_sns_topic.critical_alerts[0].arn]

  dimensions = {
    DBClusterIdentifier = aws_rds_cluster.main[0].cluster_identifier
  }

  tags = local.common_tags
}

# ALB Response Time Alarm
resource "aws_cloudwatch_metric_alarm" "alb_response_time_high" {
  count = local.monitoring_config.alb_monitoring_enabled ? 1 : 0

  alarm_name          = "${var.name}-alb-response-time-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.monitoring.alarms.aurora_cpu_evaluation_periods
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = var.monitoring.alarms.aurora_cpu_period
  statistic           = "Average"
  threshold           = var.monitoring.alarms.alb_response_time_threshold
  alarm_description   = "This metric monitors ALB response time"
  alarm_actions       = [aws_sns_topic.warning_alerts[0].arn]
  ok_actions          = [aws_sns_topic.warning_alerts[0].arn]

  dimensions = {
    LoadBalancer = aws_lb.main[0].arn_suffix
  }

  tags = local.common_tags
}

# ALB 5XX Error Rate Alarm
resource "aws_cloudwatch_metric_alarm" "alb_5xx_errors" {
  count = local.monitoring_config.alb_monitoring_enabled ? 1 : 0

  alarm_name          = "${var.name}-alb-5xx-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.monitoring.alarms.aurora_cpu_evaluation_periods
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = var.monitoring.alarms.aurora_cpu_period
  statistic           = "Sum"
  threshold           = var.monitoring.alarms.alb_5xx_error_threshold
  alarm_description   = "This metric monitors ALB 5xx errors"
  alarm_actions       = [aws_sns_topic.critical_alerts[0].arn]

  dimensions = {
    LoadBalancer = aws_lb.main[0].arn_suffix
  }

  treat_missing_data = "notBreaching"
  tags               = local.common_tags
}

# CloudFront Error Rate Alarm
resource "aws_cloudfront_monitoring_subscription" "main" {
  count = local.monitoring_config.cloudfront_monitoring_enabled ? 1 : 0

  distribution_id = aws_cloudfront_distribution.main[0].id

  monitoring_subscription {
    realtime_metrics_subscription_config {
      realtime_metrics_subscription_status = "Enabled"
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "cloudfront_5xx_errors" {
  count = local.monitoring_config.cloudfront_monitoring_enabled ? 1 : 0

  alarm_name          = "${var.name}-cloudfront-5xx-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.monitoring.alarms.aurora_cpu_evaluation_periods
  metric_name         = "5xxErrorRate"
  namespace           = "AWS/CloudFront"
  period              = var.monitoring.alarms.aurora_cpu_period
  statistic           = "Average"
  threshold           = var.monitoring.alarms.cloudfront_5xx_threshold
  alarm_description   = "This metric monitors CloudFront 5xx error rate"
  alarm_actions       = [aws_sns_topic.critical_alerts[0].arn]

  dimensions = {
    DistributionId = aws_cloudfront_distribution.main[0].id
  }

  treat_missing_data = "notBreaching"
  tags               = local.common_tags
}

# Note: ECS Service alarms moved to the bottom of the file with proper monitoring conditionals

# Log Groups are created by the service module itself

# Log Insights Queries
resource "aws_cloudwatch_query_definition" "error_logs" {
  count = length(local.services_unified_enabled) > 0 ? 1 : 0

  name = "${var.name}-error-logs"

  log_group_names = [for service, config in local.services_unified_enabled : "/aws/ecs/${var.name}/${service}"]

  query_string = <<EOF
fields @timestamp, @message, @logStream
| filter @message like /ERROR/
| sort @timestamp desc
| limit 100
EOF
}

resource "aws_cloudwatch_query_definition" "performance_logs" {
  count = length(local.services_unified_enabled) > 0 ? 1 : 0

  name = "${var.name}-performance-logs"

  log_group_names = [for service, config in local.services_unified_enabled : "/aws/ecs/${var.name}/${service}"]

  query_string = <<EOF
fields @timestamp, @message, @duration, @logStream
| filter @message like /duration/
| sort @timestamp desc
| stats avg(@duration) by bin(5m)
EOF
}

# Service-specific log queries
resource "aws_cloudwatch_query_definition" "service_logs" {
  for_each = local.services_unified_enabled

  name            = "${var.name}-${each.key}-logs"
  log_group_names = ["/aws/ecs/${var.name}/${each.key}"]

  query_string = <<EOF
fields @timestamp, @message, @logStream
| sort @timestamp desc
| limit 200
EOF
}

# Lambda-specific log queries
resource "aws_cloudwatch_query_definition" "lambda_logs" {
  for_each = local.lambda_functions_enabled

  name            = "${var.name}-lambda-${each.key}-logs"
  log_group_names = ["/aws/lambda/${var.name}-${each.key}"]

  query_string = <<EOF
fields @timestamp, @message, @logStream, @requestId
| sort @timestamp desc
| limit 200
EOF
}

# Combined Service and Lambda logs with filtering capability
resource "aws_cloudwatch_query_definition" "all_application_logs" {
  count = (length(local.services_unified_enabled) > 0 || length(local.lambda_functions_enabled) > 0) ? 1 : 0

  name = "${var.name}-all-application-logs"
  log_group_names = concat(
    [for service, config in local.services_unified_enabled : "/aws/ecs/${var.name}/${service}"],
    [for lambda_name, lambda_config in local.lambda_functions_enabled : "/aws/lambda/${var.name}-${lambda_name}"]
  )

  query_string = <<EOF
fields @timestamp, @message, @logStream
| parse @logStream /\/aws\/(ecs|lambda)\/.*?\/(?<component>.*)/
| display @timestamp, component, @message
| sort @timestamp desc
| limit 200
# Filter examples:
# | filter component = "api" (for service named 'api')
# | filter component = "data-processor" (for lambda named 'data-processor')
# | filter @logStream like /lambda/ (all lambda functions)
# | filter @logStream like /ecs/ (all services)
EOF
}

# HTTP request logs
resource "aws_cloudwatch_query_definition" "http_requests" {
  count = length(local.services_unified_enabled) > 0 ? 1 : 0

  name = "${var.name}-http-requests"

  log_group_names = [for service, config in local.services_unified_enabled : "/aws/ecs/${var.name}/${service}"]

  query_string = <<EOF
fields @timestamp, @message, @logStream
| filter @message like /GET|POST|PUT|DELETE/
| sort @timestamp desc
| limit 100
EOF
}

# Database connection logs
resource "aws_cloudwatch_query_definition" "database_logs" {
  count = length(local.services_unified_enabled) > 0 ? 1 : 0

  name = "${var.name}-database-logs"

  log_group_names = [for service, config in local.services_unified_enabled : "/aws/ecs/${var.name}/${service}"]

  query_string = <<EOF
fields @timestamp, @message, @logStream
| filter @message like /database|postgres|sql|connection/
| sort @timestamp desc
| limit 100
EOF
}

# Warning logs
resource "aws_cloudwatch_query_definition" "warning_logs" {
  count = length(local.services_unified_enabled) > 0 ? 1 : 0

  name = "${var.name}-warning-logs"

  log_group_names = [for service, config in local.services_unified_enabled : "/aws/ecs/${var.name}/${service}"]

  query_string = <<EOF
fields @timestamp, @message, @logStream
| filter @message like /WARN|WARNING/
| sort @timestamp desc
| limit 100
EOF
}

# Slow query logs
resource "aws_cloudwatch_query_definition" "slow_queries" {
  count = length(local.services_unified_enabled) > 0 ? 1 : 0

  name = "${var.name}-slow-queries"

  log_group_names = [for service, config in local.services_unified_enabled : "/aws/ecs/${var.name}/${service}"]

  query_string = <<EOF
fields @timestamp, @message, @logStream, @requestId
| filter @message like /slow|duration|ms|seconds|query.*took|execution.*time|timeout/
| filter @message like /SELECT|INSERT|UPDATE|DELETE|postgres|sql/
| sort @timestamp desc
| limit 100
EOF
}

# Slow query analysis with performance metrics
resource "aws_cloudwatch_query_definition" "slow_query_analysis" {
  count = length(local.services_unified_enabled) > 0 ? 1 : 0

  name = "${var.name}-slow-query-analysis"

  log_group_names = [for service, config in local.services_unified_enabled : "/aws/ecs/${var.name}/${service}"]

  query_string = <<EOF
fields @timestamp, @message, @logStream
| filter @message like /slow|duration|ms|seconds|query.*took|execution.*time/
| filter @message like /SELECT|INSERT|UPDATE|DELETE|postgres|sql/
| parse @message /duration:?\s*(?<duration>\d+(?:\.\d+)?)\s*(ms|seconds|s)/
| parse @message /(?<query_type>SELECT|INSERT|UPDATE|DELETE)/
| parse @message /(?<table_name>\w+)/
| stats count() as query_count, avg(duration) as avg_duration, max(duration) as max_duration by query_type, bin(5m)
| sort @timestamp desc
EOF
}

# Outputs
output "sns_critical_alerts_topic_arn" {
  value       = var.monitoring.enabled ? aws_sns_topic.critical_alerts[0].arn : null
  description = "SNS topic ARN for critical alerts"
}

output "sns_warning_alerts_topic_arn" {
  value       = var.monitoring.enabled ? aws_sns_topic.warning_alerts[0].arn : null
  description = "SNS topic ARN for warning alerts"
}

output "cloudwatch_dashboard_url" {
  value       = var.monitoring.enabled ? "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.main[0].dashboard_name}" : null
  description = "CloudWatch Dashboard URL"
}

output "cloudwatch_logs_insights_url" {
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#logsV2:logs-insights"
  description = "CloudWatch Logs Insights URL for custom queries"
}

# ECS Service CPU Utilization Alarms (per service when monitoring is enabled)
resource "aws_cloudwatch_metric_alarm" "ecs_service_cpu_high" {
  for_each = local.services_with_monitoring

  alarm_name          = "${var.name}-${each.key}-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.monitoring.alarms.ecs_cpu_evaluation_periods
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = var.monitoring.alarms.ecs_alarm_period
  statistic           = "Average"
  threshold           = var.monitoring.alarms.ecs_cpu_threshold
  alarm_description   = "This metric monitors ECS service ${each.key} CPU utilization"
  alarm_actions       = [aws_sns_topic.warning_alerts[0].arn]
  ok_actions          = [aws_sns_topic.warning_alerts[0].arn]

  dimensions = {
    ServiceName = "${var.name}-${each.key}"
    ClusterName = aws_ecs_cluster.main.name
  }

  treat_missing_data = var.monitoring.alarms.treat_missing_data
  tags               = local.common_tags
}

# ECS Service Memory Utilization Alarms (per service when monitoring is enabled)
resource "aws_cloudwatch_metric_alarm" "ecs_service_memory_high" {
  for_each = {
    for service_name, service_config in var.services : service_name => service_config
    if var.monitoring.enabled && service_config.monitoring
  }

  alarm_name          = "${var.name}-${each.key}-memory-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.monitoring.alarms.ecs_memory_evaluation_periods
  metric_name         = "MemoryUtilization"
  namespace           = "AWS/ECS"
  period              = var.monitoring.alarms.ecs_alarm_period
  statistic           = "Average"
  threshold           = var.monitoring.alarms.ecs_memory_threshold
  alarm_description   = "This metric monitors ECS service ${each.key} memory utilization"
  alarm_actions       = [aws_sns_topic.critical_alerts[0].arn]

  dimensions = {
    ServiceName = "${var.name}-${each.key}"
    ClusterName = aws_ecs_cluster.main.name
  }

  treat_missing_data = var.monitoring.alarms.treat_missing_data
  tags               = local.common_tags
}

# ECS Service Running Task Count Alarms (detects service crashes)
resource "aws_cloudwatch_metric_alarm" "ecs_service_running_tasks_low" {
  for_each = {
    for service_name, service_config in var.services : service_name => service_config
    if var.monitoring.enabled && service_config.monitoring
  }

  alarm_name          = "${var.name}-${each.key}-running-tasks-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "RunningTaskCount"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = var.monitoring.alarms.ecs_service_min_running_tasks
  alarm_description   = "This metric monitors running task count for ECS service ${each.key} - triggers on service crashes"
  alarm_actions       = [aws_sns_topic.critical_alerts[0].arn]
  ok_actions          = [aws_sns_topic.critical_alerts[0].arn]

  dimensions = {
    ServiceName = "${var.name}-${each.key}"
    ClusterName = aws_ecs_cluster.main.name
  }

  treat_missing_data = "breaching" # Missing data indicates no running tasks
  tags               = local.common_tags
}

# ALB Target Health Alarms per service (detects unhealthy services)
# Only for services with ALB target groups when ALB is enabled
resource "aws_cloudwatch_metric_alarm" "alb_unhealthy_host_count_high" {
  for_each = local.alb_enabled ? {
    for service_name, service_config in local.services_needing_alb : service_name => service_config
    if var.monitoring.enabled && service_config.monitoring
  } : {}

  alarm_name          = "${var.name}-${each.key}-unhealthy-hosts-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Average"
  threshold           = var.monitoring.alarms.alb_unhealthy_host_threshold
  alarm_description   = "This metric monitors unhealthy target count for service ${each.key}"
  alarm_actions       = [aws_sns_topic.critical_alerts[0].arn]

  dimensions = {
    TargetGroup  = module.services[each.key].target_group_arn_suffix
    LoadBalancer = aws_lb.main[0].arn_suffix
  }

  treat_missing_data = var.monitoring.alarms.treat_missing_data
  tags               = local.common_tags
}

# ALB Healthy Host Count Alarms per service (detects when no healthy targets)
# Only for services with ALB target groups when ALB is enabled
resource "aws_cloudwatch_metric_alarm" "alb_healthy_host_count_low" {
  for_each = local.alb_enabled ? {
    for service_name, service_config in local.services_needing_alb : service_name => service_config
    if var.monitoring.enabled && service_config.monitoring
  } : {}

  alarm_name          = "${var.name}-${each.key}-healthy-hosts-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  metric_name         = "HealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Average"
  threshold           = var.monitoring.alarms.alb_healthy_host_threshold
  alarm_description   = "This metric monitors healthy target count for service ${each.key}"
  alarm_actions       = [aws_sns_topic.critical_alerts[0].arn]
  ok_actions          = [aws_sns_topic.critical_alerts[0].arn]

  dimensions = {
    TargetGroup  = module.services[each.key].target_group_arn_suffix
    LoadBalancer = aws_lb.main[0].arn_suffix
  }

  treat_missing_data = "breaching" # Missing data likely indicates no healthy targets
  tags               = local.common_tags
}

# CloudWatch Metric Filters for Error Detection per service
resource "aws_cloudwatch_log_metric_filter" "service_error_count" {
  for_each = {
    for service_name, service_config in var.services : service_name => service_config
    if var.monitoring.enabled && var.monitoring.log_monitoring.enabled && service_config.monitoring
  }

  name           = "${var.name}-${each.key}-error-count"
  log_group_name = "/aws/ecs/${var.name}/${each.key}"
  pattern        = join(" ", [for pattern in var.monitoring.log_monitoring.error_patterns : "?\"${pattern}\""])

  metric_transformation {
    name      = "${var.name}-${each.key}-ErrorCount"
    namespace = "ECS/ServiceLogs"
    value     = "1"
  }

  depends_on = [module.services]
}

# CloudWatch Alarms for Service Error Rate
resource "aws_cloudwatch_metric_alarm" "service_error_rate_high" {
  for_each = {
    for service_name, service_config in var.services : service_name => service_config
    if var.monitoring.enabled && var.monitoring.log_monitoring.enabled && service_config.monitoring
  }

  alarm_name          = "${var.name}-${each.key}-error-rate-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.monitoring.log_monitoring.error_evaluation_periods
  metric_name         = "${var.name}-${each.key}-ErrorCount"
  namespace           = "ECS/ServiceLogs"
  period              = 300 # 5 minutes
  statistic           = "Sum"
  threshold           = var.monitoring.log_monitoring.error_threshold
  alarm_description   = "High error rate detected in logs for service ${each.key}"
  alarm_actions       = [aws_sns_topic.critical_alerts[0].arn]
  ok_actions          = [aws_sns_topic.critical_alerts[0].arn]

  treat_missing_data = "notBreaching"
  tags               = local.common_tags

  depends_on = [aws_cloudwatch_log_metric_filter.service_error_count]
}

output "service_log_groups" {
  value = {
    for service_name, service_config in local.services_unified_enabled : service_name => {
      log_group_name = "/aws/ecs/${var.name}/${service_name}"
      log_group_url  = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#logsV2:log-groups/log-group/${urlencode("/aws/ecs/${var.name}/${service_name}")}"
    }
  }
  description = "Enabled service log group information with direct URLs"
}

output "lambda_log_groups" {
  value = {
    for lambda_name, lambda_config in local.lambda_functions_enabled : lambda_name => {
      log_group_name = "/aws/lambda/${var.name}-${lambda_name}"
      log_group_url  = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#logsV2:log-groups/log-group/${urlencode("/aws/lambda/${var.name}-${lambda_name}")}"
    }
  }
  description = "Enabled Lambda function log group information with direct URLs"
}

output "combined_logs_insights_url" {
  value       = (length(local.services_unified_enabled) > 0 || length(local.lambda_functions_enabled) > 0) ? "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#logsV2:logs-insights$~queryDetail=~(end~0~start~-3600~timeType~'RELATIVE~unit~'seconds~editorString~'fields*20*40timestamp*2c*20*40message*2c*20*40logStream*0a*7c*20parse*20*40logStream*20*2f*5c*2faws*5c*2f*28ecs*7clambda*29*5c*2f.*3f*5c*2f*28*3fP*3ccomponent*3e.*29*2f*0a*7c*20display*20*40timestamp*2c*20component*2c*20*40message*0a*7c*20sort*20*40timestamp*20desc*0a*7c*20limit*20200~isLiveTail~false~source~(${join("~", concat([for s in keys(local.services_unified_enabled) : urlencode("/aws/ecs/${var.name}/${s}")], [for l in keys(local.lambda_functions_enabled) : urlencode("/aws/lambda/${var.name}-${l}")]))}))" : null
  description = "Direct CloudWatch Logs Insights URL with combined query for enabled services and Lambda functions"
}
