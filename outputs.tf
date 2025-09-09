# Core Infrastructure Outputs

# VPC Outputs
output "vpc_id" {
  value       = aws_vpc.main.id
  description = "ID of the VPC"
}

output "vpc_cidr_block" {
  value       = aws_vpc.main.cidr_block
  description = "CIDR block of the VPC"
}

output "vpc_arn" {
  value       = aws_vpc.main.arn
  description = "ARN of the VPC"
}

# Subnet Outputs
output "public_subnet_ids" {
  value       = aws_subnet.public[*].id
  description = "IDs of the public subnets"
}

output "private_subnet_ids" {
  value       = aws_subnet.private[*].id
  description = "IDs of the private subnets"
}

output "database_subnet_ids" {
  value       = local.database_subnets_enabled ? aws_subnet.database[*].id : []
  description = "IDs of the database subnets"
}

output "availability_zones" {
  value       = local.availability_zones
  description = "Availability zones used by the VPC"
}

# Load Balancer Outputs
output "alb_dns_name" {
  value       = local.alb_enabled ? aws_lb.main[0].dns_name : null
  description = "DNS name of the Application Load Balancer"
}

output "alb_zone_id" {
  value       = local.alb_enabled ? aws_lb.main[0].zone_id : null
  description = "Zone ID of the Application Load Balancer"
}

output "alb_arn" {
  value       = local.alb_enabled ? aws_lb.main[0].arn : null
  description = "ARN of the Application Load Balancer"
}

output "alb_security_group_id" {
  value       = local.alb_enabled ? aws_security_group.alb[0].id : null
  description = "Security Group ID of the Application Load Balancer"
}

# Database Outputs
output "database_endpoint" {
  value = local.rds_enabled ? (
    local.is_aurora ? aws_rds_cluster.main[0].endpoint : aws_db_instance.main[0].endpoint
  ) : null
  description = "Database endpoint"
  sensitive   = true
}

output "database_port" {
  value = local.rds_enabled ? (
    local.is_aurora ? aws_rds_cluster.main[0].port : aws_db_instance.main[0].port
  ) : null
  description = "Database port"
}

output "database_name" {
  value = local.rds_enabled ? (
    local.is_aurora ? aws_rds_cluster.main[0].database_name : aws_db_instance.main[0].db_name
  ) : null
  description = "Database name"
}

output "database_secret_arn" {
  value       = local.rds_enabled ? aws_secretsmanager_secret.database_url[0].arn : null
  description = "ARN of the database connection string secret"
}

# RDS Proxy endpoint is defined in rds.tf to avoid duplication

# S3 Outputs
output "s3_bucket_id" {
  value       = local.s3_enabled ? aws_s3_bucket.main[0].id : null
  description = "S3 bucket ID"
}

output "s3_bucket_arn" {
  value       = local.s3_enabled ? aws_s3_bucket.main[0].arn : null
  description = "S3 bucket ARN"
}

output "s3_bucket_domain_name" {
  value       = local.s3_enabled ? aws_s3_bucket.main[0].bucket_domain_name : null
  description = "S3 bucket domain name"
}

output "s3_bucket_regional_domain_name" {
  value       = local.s3_enabled ? aws_s3_bucket.main[0].bucket_regional_domain_name : null
  description = "S3 bucket regional domain name"
}

# CloudFront Outputs (avoiding duplicates with cloudfront.tf)
output "cloudfront_arn" {
  value       = local.s3_enabled && var.s3.public != null ? aws_cloudfront_distribution.main[0].arn : null
  description = "CloudFront distribution ARN"
}

# DNS Outputs
output "route53_zone_id" {
  value       = var.dns.domain != null ? data.aws_route53_zone.main[0].zone_id : null
  description = "Route53 hosted zone ID"
}

output "acm_certificate_arn" {
  value       = var.dns.domain != null ? aws_acm_certificate.main[0].arn : null
  description = "ACM certificate ARN"
}

output "domain_name" {
  value       = var.dns.domain
  description = "Primary domain name"
}

# ECS Cluster Outputs
output "ecs_cluster_id" {
  value       = local.fargate_enabled ? aws_ecs_cluster.main.id : null
  description = "ECS cluster ID"
}

output "ecs_cluster_arn" {
  value       = local.fargate_enabled ? aws_ecs_cluster.main.arn : null
  description = "ECS cluster ARN"
}

output "ecs_cluster_name" {
  value       = local.fargate_enabled ? aws_ecs_cluster.main.name : null
  description = "ECS cluster name"
}

# Service Outputs - removed duplicate (exists in services.tf)

# Lambda Outputs
# Lambda outputs are defined in lambda.tf to avoid duplication

# Monitoring Outputs
output "monitoring" {
  value = var.monitoring.enabled ? {
    dashboard_url = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.main[0].dashboard_name}"

    sns_topics = {
      critical_alerts_arn = aws_sns_topic.critical_alerts[0].arn
      warning_alerts_arn  = aws_sns_topic.warning_alerts[0].arn
    }

    log_groups = merge(
      # Service log groups
      {
        for service_name, service_config in var.services :
        "service_${service_name}" => "/aws/ecs/${var.name}/${service_name}"
      },
      # Lambda log groups
      {
        for lambda_name, lambda_config in var.lambda.functions :
        "lambda_${lambda_name}" => "/aws/lambda/${var.name}-${lambda_name}"
      },
      # Infrastructure log groups
      local.rds_enabled ? {
        rds_postgresql = "/aws/rds/instance/${local.is_aurora ? aws_rds_cluster.main[0].cluster_identifier : aws_db_instance.main[0].identifier}/postgresql"
      } : {},
      var.vpc.flow_logs.enabled ? {
        vpc_flow_logs = "/aws/vpc/flowlogs/${var.name}"
      } : {}
    )

    log_insights_url = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#logsV2:logs-insights"
  } : null
  description = "Monitoring and logging information"
}

# SES Outputs - removed duplicate (exists in ses.tf)

# Bastion Outputs - removed duplicate (exists in bastion.tf)

# Security Group Outputs
output "security_groups" {
  value = {
    vpc_endpoints = var.vpc.endpoints.enabled ? aws_security_group.vpc_endpoints[0].id : null
    alb           = local.alb_enabled ? aws_security_group.alb[0].id : null
    rds           = local.rds_enabled ? aws_security_group.rds[0].id : null
    bastion = local.bastion_enabled ? {
      for name, sg in aws_security_group.bastion : name => sg.id
    } : {}

    # Lambda shared security group (for database, secrets, and network access)
    lambda_shared = local.lambda_needs_vpc ? aws_security_group.lambda_shared[0].id : null
  }
  description = "Security group IDs for various components"
}

# Network Information
output "network_info" {
  value = {
    vpc_cidr           = aws_vpc.main.cidr_block
    public_subnets     = aws_subnet.public[*].cidr_block
    private_subnets    = aws_subnet.private[*].cidr_block
    database_subnets   = local.database_subnets_enabled ? aws_subnet.database[*].cidr_block : []
    availability_zones = local.availability_zones

    nat_gateway_ips = var.vpc.nat_gateway.enabled ? aws_eip.nat[*].public_ip : []

    # VPC Endpoints
    vpc_endpoints = var.vpc.endpoints.enabled && local.vpc_endpoints_defaults.s3_enabled ? {
      s3 = local.vpc_endpoints_defaults.s3_enabled ? {
        id           = aws_vpc_endpoint.s3[0].id
        service_name = aws_vpc_endpoint.s3[0].service_name
      } : null

      ecr_api = local.vpc_endpoints_defaults.ecr_api_enabled ? {
        id           = aws_vpc_endpoint.ecr_api[0].id
        service_name = aws_vpc_endpoint.ecr_api[0].service_name
        dns_names    = aws_vpc_endpoint.ecr_api[0].dns_entry[*].dns_name
      } : null

      ecr_dkr = local.vpc_endpoints_defaults.ecr_dkr_enabled ? {
        id           = aws_vpc_endpoint.ecr_dkr[0].id
        service_name = aws_vpc_endpoint.ecr_dkr[0].service_name
        dns_names    = aws_vpc_endpoint.ecr_dkr[0].dns_entry[*].dns_name
      } : null
    } : null
  }
  description = "Network configuration details"
}

# Application URLs (Convenience Output)
output "application_urls" {
  value = merge(
    # Primary application URL
    var.dns.domain != null ? {
      primary = "https://${var.dns.domain}"
      www     = "https://www.${var.dns.domain}"
    } : {},

    # Service-specific URLs
    {
      for name, config in var.services : name => (
        config.http != null && config.http.subdomain != null ?
        "https://${config.http.subdomain}.${var.dns.domain}" :
        config.http != null && config.http.path_pattern != null ?
        "https://${var.dns.domain}${config.http.path_pattern}" :
        local.alb_enabled ? "https://${aws_lb.main[0].dns_name}" : null
      )
      if var.dns.domain != null || local.alb_enabled
    },

    # Lambda HTTP URLs
    {
      for name, config in local.lambda_with_http : "lambda_${name}" => (
        config.triggers.http.subdomain != null ?
        "https://${config.triggers.http.subdomain}.${var.dns.domain}" :
        config.triggers.http.path_pattern != null ?
        "https://${var.dns.domain}${config.triggers.http.path_pattern}" :
        module.lambda_functions[name].api_gateway_url
      )
    },

    # CloudFront URL
    local.s3_enabled && var.s3.public != null ? {
      cdn = "https://${aws_cloudfront_distribution.main[0].domain_name}"
    } : {},

    # Monitoring and admin URLs
    var.monitoring.enabled ? {
      dashboard = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.main[0].dashboard_name}"
      logs      = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#logsV2:logs-insights"
    } : {}
  )
  description = "All application and service URLs"
}

# Security Warnings
output "security_warnings" {
  value = compact(flatten([
    # Bastion host with wide-open access warning
    [
      for name, config in local.bastion_configs_enabled :
      contains(config.allowed_cidr_blocks, "0.0.0.0/0") ?
      "⚠️  WARNING: Bastion host '${name}' allows access from 0.0.0.0/0 (entire internet). This is strongly discouraged in production environments." : null
    ]
  ]))
  description = "Security warnings and recommendations"
}

# Resource ARNs (for cross-stack references)
output "resource_arns" {
  value = {
    vpc                   = aws_vpc.main.arn
    s3_bucket             = local.s3_enabled ? aws_s3_bucket.main[0].arn : null
    rds_cluster           = local.rds_enabled && local.is_aurora ? aws_rds_cluster.main[0].arn : null
    rds_instance          = local.rds_enabled && local.is_postgres ? aws_db_instance.main[0].arn : null
    ecs_cluster           = local.fargate_enabled ? aws_ecs_cluster.main.arn : null
    alb                   = local.alb_enabled ? aws_lb.main[0].arn : null
    cloudfront            = local.s3_enabled && var.s3.public != null ? aws_cloudfront_distribution.main[0].arn : null
    acm_certificate       = var.dns.domain != null ? aws_acm_certificate.main[0].arn : null
    critical_alerts_topic = var.monitoring.enabled ? aws_sns_topic.critical_alerts[0].arn : null
    warning_alerts_topic  = var.monitoring.enabled ? aws_sns_topic.warning_alerts[0].arn : null
  }
  description = "ARNs of major resources for cross-stack references"
}

