# RDS Configuration - supports both Aurora PostgreSQL and standard PostgreSQL

# Only create RDS resources if enabled
locals {
  # create_rds and is_aurora now defined in locals.tf
  is_postgres = var.rds.engine_type == "postgres"
  db_name     = local.computed_db_name # Use centrally computed database name

  # Extract password from AWS-managed secret JSON (only for password-based auth)
  aws_managed_secret_json = local.rds_enabled && (!local.is_aurora || !var.rds.iam_database_authentication) ? jsondecode(data.aws_secretsmanager_secret_version.aws_managed_password[0].secret_string) : {}
  db_password             = local.rds_enabled && (!local.is_aurora || !var.rds.iam_database_authentication) ? local.aws_managed_secret_json.password : ""

  # URL encode the password and username for safe use in DATABASE_URL
  url_encoded_password = local.rds_enabled && (!local.is_aurora || !var.rds.iam_database_authentication) ? urlencode(local.db_password) : ""
  url_encoded_username = local.rds_enabled ? urlencode(var.rds.username) : ""
  url_encoded_database = local.rds_enabled ? urlencode(local.db_name) : ""

  # Database endpoint (use local DNS names instead of direct RDS endpoints)
  db_endpoint    = local.rds_enabled ? "db.${var.name}.local" : ""
  db_ro_endpoint = local.rds_enabled && local.is_aurora ? "db-ro.${var.name}.local" : ""
  proxy_endpoint = local.rds_enabled && var.rds.proxy ? "db-proxy.${var.name}.local" : ""
}

# Data source to fetch the AWS-managed database password
data "aws_secretsmanager_secret_version" "aws_managed_password" {
  count = local.rds_enabled && (!local.is_aurora || !var.rds.iam_database_authentication) ? 1 : 0

  secret_id = local.is_aurora ? aws_rds_cluster.main[0].master_user_secret[0].secret_arn : aws_db_instance.main[0].master_user_secret[0].secret_arn
}


# Store DATABASE_URL in Secrets Manager
resource "aws_secretsmanager_secret" "database_url" {
  count = local.rds_enabled ? 1 : 0

  name                    = "${var.name}-database-url"
  description             = "Complete DATABASE_URL for PostgreSQL connection"
  recovery_window_in_days = 7

  tags = local.common_tags
}

resource "aws_secretsmanager_secret_version" "database_url" {
  count = local.rds_enabled ? 1 : 0

  secret_id = aws_secretsmanager_secret.database_url[0].id
  secret_string = jsonencode(merge(
    {
      # AWS-managed master user secret ARN (contains the actual password)
      AWS_MANAGED_SECRET_ARN = local.is_aurora ? aws_rds_cluster.main[0].master_user_secret[0].secret_arn : aws_db_instance.main[0].master_user_secret[0].secret_arn

      # Connection endpoints and basic info
      RDS_ENDPOINT = local.db_endpoint
      RDS_USERNAME = var.rds.username
      RDS_DATABASE = local.db_name
      RDS_PORT     = "5432"

      # Legacy DATABASE_URL - properly URL-encoded with actual password or IAM auth
      DATABASE_URL = local.is_aurora && var.rds.iam_database_authentication ? (
        var.rds.proxy ? "postgres://${local.url_encoded_username}@${local.proxy_endpoint}/${local.url_encoded_database}?sslmode=require" : "postgres://${local.url_encoded_username}@${local.db_endpoint}/${local.url_encoded_database}?sslmode=require"
        ) : (
        var.rds.proxy ? "postgres://${local.url_encoded_username}:${local.url_encoded_password}@${local.proxy_endpoint}/${local.url_encoded_database}?sslmode=require" : "postgres://${local.url_encoded_username}:${local.url_encoded_password}@${local.db_endpoint}/${local.url_encoded_database}?sslmode=require"
      )

      # Active URL - properly URL-encoded with actual password or IAM auth
      DATABASE_URL_ACTIVE = local.is_aurora && var.rds.iam_database_authentication ? (
        # For Aurora with IAM auth enabled, no password needed
        var.rds.proxy ? "postgres://${local.url_encoded_username}@${local.proxy_endpoint}/${local.url_encoded_database}?sslmode=require" : "postgres://${local.url_encoded_username}@${local.db_endpoint}/${local.url_encoded_database}?sslmode=require"
        ) : (
        # For password-based auth, use URL-encoded password
        var.rds.proxy ? "postgres://${local.url_encoded_username}:${local.url_encoded_password}@${local.proxy_endpoint}/${local.url_encoded_database}?sslmode=require" : "postgres://${local.url_encoded_username}:${local.url_encoded_password}@${local.db_endpoint}/${local.url_encoded_database}?sslmode=require"
      )
    },
    # Only include IAM URL if Aurora with IAM auth is enabled (no password needed)
    local.is_aurora && var.rds.iam_database_authentication ? {
      DATABASE_URL_IAM = "postgres://${local.url_encoded_username}@${local.db_endpoint}/${local.url_encoded_database}?sslmode=require"
    } : {},
    # Proxy endpoints (for reference)
    var.rds.proxy ? {
      RDS_PROXY_ENDPOINT = local.proxy_endpoint
    } : {},
    # Only include proxy IAM URL if proxy and Aurora IAM auth are enabled
    var.rds.proxy && local.is_aurora && var.rds.iam_database_authentication ? {
      DATABASE_URL_PROXY_IAM = "postgres://${local.url_encoded_username}@${local.proxy_endpoint}/${local.url_encoded_database}?sslmode=require"
    } : {}
  ))

  lifecycle {
    replace_triggered_by = [aws_secretsmanager_secret.database_url[0]]
    ignore_changes       = [secret_string]
  }
}

# DB Subnet Group (used by both Aurora and standard PostgreSQL)
resource "aws_db_subnet_group" "main" {
  count = local.rds_enabled ? 1 : 0

  name = "${var.name}-rds-subnet-group"
  subnet_ids = var.rds.network_access != null ? aws_subnet.public[*].id : (
    local.database_subnet_count > 0 ? aws_subnet.database[*].id : aws_subnet.private[*].id
  )

  tags = merge(local.common_tags, {
    Name = "${var.name}-rds-subnet-group"
  })
}

# Security Group for RDS
resource "aws_security_group" "rds" {
  count = local.rds_enabled ? 1 : 0

  name_prefix = "${var.name}-rds-"
  vpc_id      = aws_vpc.main.id

  # No default ingress rules - access is granted via explicit security group rules only

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All outbound traffic"
  }

  tags = merge(local.common_tags, {
    Name = "${var.name}-rds-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# Security group rule for public network access to RDS (when network_access.cidrs is configured)
resource "aws_security_group_rule" "rds_public_access" {
  count = local.rds_enabled && var.rds.network_access != null && length(var.rds.network_access.cidrs) > 0 ? 1 : 0

  type              = "ingress"
  from_port         = 5432
  to_port           = 5432
  protocol          = "tcp"
  cidr_blocks       = var.rds.network_access.cidrs
  security_group_id = aws_security_group.rds[0].id
  description       = "PostgreSQL public access from specified CIDRs"
}

# Security group rules for service access to RDS (only for services with database = true)
resource "aws_security_group_rule" "services_to_rds" {
  for_each = local.rds_enabled && local.services_need_database ? local.services_with_database : {}

  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = module.services[each.key].security_group_id
  security_group_id        = aws_security_group.rds[0].id
  description              = "PostgreSQL from ${each.key} service"
}

# Lambda security groups for database access
# Shared Lambda Security Group for database and secrets access
resource "aws_security_group" "lambda_shared" {
  count = local.lambda_needs_vpc ? 1 : 0

  name_prefix = "${var.name}-lambda-shared-"
  vpc_id      = aws_vpc.main.id

  # No inline egress rules - all managed as separate resources

  tags = merge(local.common_tags, {
    Name = "${var.name}-lambda-shared-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# Security group rules for lambda access to RDS (for lambdas with VPC config)
resource "aws_security_group_rule" "lambda_to_rds" {
  count = local.lambda_needs_database && local.rds_enabled ? 1 : 0

  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.lambda_shared[0].id
  security_group_id        = aws_security_group.rds[0].id
  description              = "PostgreSQL from Lambda functions"
}

# Egress rule from Lambda to RDS
resource "aws_security_group_rule" "lambda_to_rds_egress" {
  count = local.lambda_needs_database && local.rds_enabled ? 1 : 0

  type                     = "egress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.rds[0].id
  security_group_id        = aws_security_group.lambda_shared[0].id
  description              = "PostgreSQL to RDS from Lambda functions"
}

# Egress rule from Lambda to VPC endpoints (HTTPS)
resource "aws_security_group_rule" "lambda_to_https_egress" {
  count = local.lambda_needs_database ? 1 : 0

  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = [aws_vpc.main.cidr_block]
  security_group_id = aws_security_group.lambda_shared[0].id
  description       = "HTTPS to VPC endpoints and services"
}

# Egress rules from Lambda to S3 service CIDR ranges (only when S3 access is needed)
resource "aws_security_group_rule" "lambda_to_s3_egress" {
  count = length(local.lambda_functions_needing_s3) > 0 && local.lambda_needs_vpc ? length(data.aws_prefix_list.s3[0].cidr_blocks) : 0

  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = [data.aws_prefix_list.s3[0].cidr_blocks[count.index]]
  security_group_id = aws_security_group.lambda_shared[0].id
  description       = "HTTPS to S3 service endpoints"
}

# Data source for S3 prefix list (when needed)
data "aws_prefix_list" "s3" {
  count = length(local.lambda_functions_needing_s3) > 0 && local.lambda_needs_vpc ? 1 : 0
  name  = "com.amazonaws.${var.aws_region}.s3"
}

# Dynamic security group rules for Lambda network access
locals {
  # Flatten all network access rules from all lambda functions (global + function-specific)
  lambda_network_access_rules = flatten([
    for func_name, func_config in local.lambda_functions_with_vpc_access : [
      for rule in concat(var.lambda.network_access, func_config.network_access) : {
        rule_id  = "${func_name}-${rule.protocol}-${join("-", rule.ports)}-${replace(join("-", rule.cidrs), "/", "_")}"
        protocol = rule.protocol
        ports    = rule.ports
        cidrs    = rule.cidrs
      }
    ]
  ])

  # Deduplicate rules (same protocol, ports, cidrs should be one rule)
  unique_network_access_rules = {
    for rule in local.lambda_network_access_rules :
    "${rule.protocol}-${join("-", rule.ports)}-${replace(join("-", rule.cidrs), "/", "_")}" => rule
  }
}

# Dynamic egress rules for Lambda network access
resource "aws_security_group_rule" "lambda_network_access" {
  for_each = local.unique_network_access_rules

  type              = "egress"
  from_port         = length(each.value.ports) == 1 ? each.value.ports[0] : min(each.value.ports...)
  to_port           = length(each.value.ports) == 1 ? each.value.ports[0] : max(each.value.ports...)
  protocol          = each.value.protocol == "all" ? "-1" : each.value.protocol
  security_group_id = aws_security_group.lambda_shared[0].id
  cidr_blocks       = each.value.cidrs
  description       = "Lambda network access: ${each.value.protocol}:${join(",", each.value.ports)} to ${join(",", each.value.cidrs)}"
}

# Lambda-to-ECS Fargate security group rules
locals {
  # Functions that need Fargate access
  lambda_functions_with_fargate = {
    for name, config in local.lambda_functions_enabled : name => config
    if config.fargate == true
  }


  # Create rule combinations for each Lambda function that needs Fargate access and each HTTP service
  lambda_to_ecs_rules = flatten([
    for lambda_name, lambda_config in local.lambda_functions_with_fargate : [
      for service_name, service_config in local.http_services : {
        lambda_name  = lambda_name
        service_name = service_name
        rule_id      = "${lambda_name}-to-${service_name}"
        port         = service_config.http.port
      }
    ]
  ])
}

# Security group rules for Lambda to call ECS services (egress from Lambda)
resource "aws_security_group_rule" "lambda_to_ecs_egress" {
  for_each = local.lambda_needs_vpc && length(local.lambda_functions_with_fargate) > 0 && length(local.http_services) > 0 ? {
    for rule in local.lambda_to_ecs_rules : rule.rule_id => rule
  } : {}

  type                     = "egress"
  from_port                = each.value.port
  to_port                  = each.value.port
  protocol                 = "tcp"
  security_group_id        = aws_security_group.lambda_shared[0].id
  source_security_group_id = module.services[each.value.service_name].security_group_id
  description              = "Lambda to ECS service port ${each.value.port}"
}

# Security group rules for ECS services to accept Lambda calls (ingress to ECS)
resource "aws_security_group_rule" "ecs_from_lambda_ingress" {
  for_each = length(local.lambda_functions_with_fargate) > 0 && length(local.http_services) > 0 ? {
    for rule in local.lambda_to_ecs_rules : rule.rule_id => rule
  } : {}

  type                     = "ingress"
  from_port                = each.value.port
  to_port                  = each.value.port
  protocol                 = "tcp"
  security_group_id        = module.services[each.value.service_name].security_group_id
  source_security_group_id = local.lambda_needs_vpc ? aws_security_group.lambda_shared[0].id : null
  description              = "ECS service port ${each.value.port} from Lambda"
}

# CloudWatch Log Group for RDS
resource "aws_cloudwatch_log_group" "rds" {
  count = local.rds_enabled ? 1 : 0

  name              = "/aws/rds/${local.is_aurora ? "cluster" : "instance"}/${var.name}/postgresql"
  retention_in_days = var.rds.log_retention_days

  # Encryption configuration
  kms_key_id = (var.logging.kms != null && var.logging.kms != false && var.logging.kms != true) ? var.logging.kms : null

  tags = local.common_tags
}

# IAM Role for Enhanced Monitoring
resource "aws_iam_role" "rds_enhanced_monitoring" {
  count = local.rds_enabled && var.rds.monitoring_interval > 0 ? 1 : 0

  name = "${var.name}-rds-enhanced-monitoring"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "monitoring.rds.amazonaws.com"
        }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "rds_enhanced_monitoring" {
  count = local.rds_enabled && var.rds.monitoring_interval > 0 ? 1 : 0

  role       = aws_iam_role.rds_enhanced_monitoring[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# ================================
# AURORA POSTGRESQL RESOURCES
# ================================

# DB Cluster Parameter Group for Aurora PostgreSQL
resource "aws_rds_cluster_parameter_group" "aurora" {
  count = local.rds_enabled && local.is_aurora ? 1 : 0

  family = "aurora-postgresql${floor(var.rds.engine_version)}"
  name   = "${var.name}-aurora-cluster-params"

  parameter {
    name  = "log_statement"
    value = "mod" # Log all DDL and data-modifying statements for security auditing
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  parameter {
    name         = "shared_preload_libraries"
    value        = "pg_stat_statements"
    apply_method = "pending-reboot"
  }

  # Custom Aurora cluster parameters (exclude hardcoded ones to prevent duplicates)
  dynamic "parameter" {
    for_each = {
      for k, v in var.rds.parameter_groups.aurora_parameters : k => v
      if !contains(["log_statement", "log_min_duration_statement", "shared_preload_libraries"], k)
    }
    content {
      name  = parameter.key
      value = parameter.value
      apply_method = contains([
        "shared_preload_libraries",
        "log_destination",
        "log_directory",
        "log_filename",
        "log_rotation_age",
        "log_rotation_size",
        "log_truncate_on_rotation",
        "logging_collector",
        "port",
        "unix_socket_directories",
        "unix_socket_group",
        "unix_socket_permissions"
      ], parameter.key) ? "pending-reboot" : "immediate"
    }
  }

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true
  }
}

# DB Parameter Group for Aurora PostgreSQL instances
resource "aws_db_parameter_group" "aurora" {
  count = local.rds_enabled && local.is_aurora ? 1 : 0

  family = "aurora-postgresql${floor(var.rds.engine_version)}"
  name   = "${var.name}-aurora-instance-params"

  parameter {
    name         = "work_mem"
    value        = "16384"
    apply_method = "immediate"
  }

  parameter {
    name         = "maintenance_work_mem"
    value        = "2048000"
    apply_method = "immediate"
  }

  # Custom instance parameters (for Aurora instances - exclude hardcoded ones to prevent duplicates)
  dynamic "parameter" {
    for_each = {
      for k, v in var.rds.parameter_groups.instance_parameters : k => v
      if !contains(["work_mem", "maintenance_work_mem"], k)
    }
    content {
      name  = parameter.key
      value = parameter.value
      apply_method = contains([
        "shared_preload_libraries",
        "log_destination",
        "log_directory",
        "log_filename",
        "log_rotation_age",
        "log_rotation_size",
        "log_truncate_on_rotation",
        "logging_collector",
        "port",
        "unix_socket_directories",
        "unix_socket_group",
        "unix_socket_permissions"
      ], parameter.key) ? "pending-reboot" : "immediate"
    }
  }

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true
  }
}

# Aurora Serverless v2 Cluster
resource "aws_rds_cluster" "main" {
  count = local.rds_enabled && local.is_aurora ? 1 : 0

  cluster_identifier = "${var.name}-aurora-cluster"
  engine             = "aurora-postgresql"
  engine_version     = var.rds.engine_version

  database_name               = local.db_name
  master_username             = var.rds.username
  manage_master_user_password = true

  # Network
  db_subnet_group_name   = aws_db_subnet_group.main[0].name
  vpc_security_group_ids = [aws_security_group.rds[0].id]

  # Parameter Groups
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.aurora[0].name

  # Backup
  backup_retention_period      = var.rds.backup_retention_period
  preferred_backup_window      = var.rds.backup_window
  preferred_maintenance_window = var.rds.maintenance_window
  copy_tags_to_snapshot        = true

  # Monitoring
  enabled_cloudwatch_logs_exports = ["postgresql"]
  monitoring_interval             = var.rds.monitoring_interval
  monitoring_role_arn             = var.rds.monitoring_interval > 0 ? aws_iam_role.rds_enhanced_monitoring[0].arn : null

  # Security
  storage_encrypted                   = var.rds.kms != null && var.rds.kms != false
  kms_key_id                          = (var.rds.kms != null && var.rds.kms != false && var.rds.kms != true) ? var.rds.kms : null
  deletion_protection                 = var.rds.deletion_protection
  skip_final_snapshot                 = var.rds.skip_final_snapshot
  iam_database_authentication_enabled = var.rds.iam_database_authentication

  # Serverless v2 scaling configuration
  dynamic "serverlessv2_scaling_configuration" {
    for_each = var.rds.aurora_config.serverless_enabled ? [1] : []
    content {
      max_capacity = var.rds.aurora_config.serverless_max_capacity
      min_capacity = var.rds.aurora_config.serverless_min_capacity
    }
  }

  tags = merge(local.common_tags, var.rds.tags, {
    Name = "${var.name}-aurora-cluster"
  })

  depends_on = [aws_cloudwatch_log_group.rds]
}

# Aurora Instances
resource "aws_rds_cluster_instance" "main" {
  count = local.rds_enabled && local.is_aurora ? var.rds.aurora_config.instance_count : 0

  cluster_identifier = aws_rds_cluster.main[0].id
  identifier         = "${var.name}-aurora-instance-${count.index + 1}"
  engine             = aws_rds_cluster.main[0].engine
  engine_version     = aws_rds_cluster.main[0].engine_version
  instance_class     = var.rds.aurora_config.serverless_enabled ? "db.serverless" : var.rds.aurora_config.instance_class

  # Performance Insights
  performance_insights_enabled          = var.rds.performance_insights_enabled
  performance_insights_retention_period = var.rds.performance_insights_enabled ? 7 : null

  # Parameter Group
  db_parameter_group_name = aws_db_parameter_group.aurora[0].name

  # Single AZ for cost savings when instance_count = 1
  availability_zone = var.rds.aurora_config.instance_count == 1 ? data.aws_availability_zones.available.names[0] : null

  # Maintenance
  auto_minor_version_upgrade = var.rds.auto_minor_version_upgrade

  tags = merge(local.common_tags, var.rds.tags, {
    Name = "${var.name}-aurora-instance-${count.index + 1}"
  })
}

# ================================
# STANDARD POSTGRESQL RESOURCES
# ================================

# DB Parameter Group for standard PostgreSQL
resource "aws_db_parameter_group" "postgres" {
  count = local.rds_enabled && local.is_postgres ? 1 : 0

  family = "postgres${floor(var.rds.engine_version)}"
  name   = "${var.name}-postgres-params"

  parameter {
    name  = "log_statement"
    value = "mod" # Log all DDL and data-modifying statements for security auditing
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  parameter {
    name         = "shared_preload_libraries"
    value        = "pg_stat_statements"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "work_mem"
    value        = "16384"
    apply_method = "immediate"
  }

  # Custom instance parameters (for standard PostgreSQL - exclude hardcoded ones to prevent duplicates)
  dynamic "parameter" {
    for_each = {
      for k, v in var.rds.parameter_groups.instance_parameters : k => v
      if !contains(["log_statement", "log_min_duration_statement", "shared_preload_libraries", "work_mem"], k)
    }
    content {
      name  = parameter.key
      value = parameter.value
      apply_method = contains([
        "shared_preload_libraries",
        "log_destination",
        "log_directory",
        "log_filename",
        "log_rotation_age",
        "log_rotation_size",
        "log_truncate_on_rotation",
        "logging_collector",
        "port",
        "unix_socket_directories",
        "unix_socket_group",
        "unix_socket_permissions"
      ], parameter.key) ? "pending-reboot" : "immediate"
    }
  }

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true
  }
}

# Standard PostgreSQL Instance
resource "aws_db_instance" "main" {
  count = local.rds_enabled && local.is_postgres ? 1 : 0

  identifier = "${var.name}-postgres"

  # Engine
  engine         = "postgres"
  engine_version = var.rds.engine_version
  instance_class = var.rds.postgres_config.instance_class

  # Database
  db_name                     = local.db_name
  username                    = var.rds.username
  manage_master_user_password = true

  # Storage
  allocated_storage     = var.rds.postgres_config.allocated_storage
  max_allocated_storage = var.rds.postgres_config.max_allocated_storage
  storage_type          = var.rds.postgres_config.storage_type
  storage_encrypted     = var.rds.kms != null && var.rds.kms != false
  kms_key_id            = (var.rds.kms != null && var.rds.kms != false && var.rds.kms != true) ? var.rds.kms : null

  # Network
  db_subnet_group_name   = aws_db_subnet_group.main[0].name
  vpc_security_group_ids = [aws_security_group.rds[0].id]
  publicly_accessible    = var.rds.network_access != null

  # High Availability
  multi_az          = var.rds.postgres_config.multi_az
  availability_zone = var.rds.postgres_config.multi_az ? null : data.aws_availability_zones.available.names[0]

  # Parameter Group
  parameter_group_name = aws_db_parameter_group.postgres[0].name

  # Backup
  backup_retention_period = var.rds.backup_retention_period
  backup_window           = var.rds.backup_window
  maintenance_window      = var.rds.maintenance_window
  copy_tags_to_snapshot   = true

  # Monitoring
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
  monitoring_interval             = var.rds.monitoring_interval
  monitoring_role_arn             = var.rds.monitoring_interval > 0 ? aws_iam_role.rds_enhanced_monitoring[0].arn : null

  # Performance Insights
  performance_insights_enabled          = var.rds.performance_insights_enabled
  performance_insights_retention_period = var.rds.performance_insights_enabled ? 7 : null

  # Security and Maintenance
  deletion_protection        = var.rds.deletion_protection
  skip_final_snapshot        = var.rds.skip_final_snapshot
  auto_minor_version_upgrade = var.rds.auto_minor_version_upgrade

  tags = merge(local.common_tags, var.rds.tags, {
    Name = "${var.name}-postgres"
  })

  depends_on = [aws_cloudwatch_log_group.rds]
}

# ================================
# COMMON RESOURCES (BOTH TYPES)
# ================================

# DNS records for database hostname (using local zone from dns.tf)
resource "aws_route53_record" "db" {
  count = local.rds_enabled ? 1 : 0

  zone_id = aws_route53_zone.local.zone_id
  name    = "db"
  type    = "CNAME"
  ttl     = 300

  records = [local.is_aurora ? aws_rds_cluster.main[0].endpoint : split(":", aws_db_instance.main[0].endpoint)[0]]
}

resource "aws_route53_record" "db_ro" {
  count = local.rds_enabled && local.is_aurora ? 1 : 0

  zone_id = aws_route53_zone.local.zone_id
  name    = "db-ro"
  type    = "CNAME"
  ttl     = 300

  records = [aws_rds_cluster.main[0].reader_endpoint]
}

resource "aws_route53_record" "db_proxy" {
  count = local.rds_enabled && var.rds.proxy ? 1 : 0

  zone_id = aws_route53_zone.local.zone_id
  name    = "db-proxy"
  type    = "CNAME"
  ttl     = 300

  records = [aws_db_proxy.main[0].endpoint]
}

# RDS Proxy (optional, works with both Aurora and standard PostgreSQL)
resource "aws_iam_role" "rds_proxy" {
  count = local.rds_enabled && var.rds.proxy ? 1 : 0

  name = "${var.name}-rds-proxy-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "rds.amazonaws.com"
        }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "rds_proxy_secrets" {
  count = local.rds_enabled && var.rds.proxy ? 1 : 0

  name = "${var.name}-rds-proxy-secrets"
  role = aws_iam_role.rds_proxy[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = [
          # Use AWS-managed secret for RDS authentication
          local.is_aurora ? aws_rds_cluster.main[0].master_user_secret[0].secret_arn : aws_db_instance.main[0].master_user_secret[0].secret_arn
        ]
      }
    ]
  })
}

resource "aws_security_group" "rds_proxy" {
  count = local.rds_enabled && var.rds.proxy ? 1 : 0

  name_prefix = "${var.name}-rds-proxy-"
  vpc_id      = aws_vpc.main.id

  # No default ingress rules - access is granted via explicit security group rules only

  egress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.rds[0].id]
    description     = "PostgreSQL to RDS"
  }

  tags = merge(local.common_tags, {
    Name = "${var.name}-rds-proxy-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# Security group rules for service access to RDS Proxy (only for services with database = true)
resource "aws_security_group_rule" "services_to_rds_proxy" {
  for_each = local.rds_enabled && var.rds.proxy && local.services_need_database ? local.services_with_database : {}

  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = module.services[each.key].security_group_id
  security_group_id        = aws_security_group.rds_proxy[0].id
  description              = "PostgreSQL from ${each.key} service"
}

# Security group rules for lambda access to RDS Proxy
resource "aws_security_group_rule" "lambda_to_rds_proxy" {
  count = local.lambda_needs_database && local.rds_enabled && var.rds.proxy ? 1 : 0

  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.lambda_shared[0].id
  security_group_id        = aws_security_group.rds_proxy[0].id
  description              = "PostgreSQL from Lambda functions"
}

resource "aws_db_proxy" "main" {
  count = local.rds_enabled && var.rds.proxy ? 1 : 0

  name                = "${var.name}-rds-proxy"
  engine_family       = "POSTGRESQL"
  debug_logging       = false
  idle_client_timeout = 1800
  require_tls         = true

  auth {
    auth_scheme = "SECRETS"
    # Use AWS-managed secret for RDS authentication
    secret_arn = local.is_aurora ? aws_rds_cluster.main[0].master_user_secret[0].secret_arn : aws_db_instance.main[0].master_user_secret[0].secret_arn
  }

  role_arn               = aws_iam_role.rds_proxy[0].arn
  vpc_subnet_ids         = local.database_subnet_count > 0 ? aws_subnet.database[*].id : aws_subnet.private[*].id
  vpc_security_group_ids = [aws_security_group.rds_proxy[0].id]

  # Targets are defined separately using aws_db_proxy_target resource

  tags = merge(local.common_tags, {
    Name = "${var.name}-rds-proxy"
  })

  lifecycle {
    ignore_changes = [auth]
  }

  depends_on = [aws_iam_role_policy.rds_proxy_secrets]
}

# RDS Proxy Default Target Group
resource "aws_db_proxy_default_target_group" "main" {
  count = local.rds_enabled && var.rds.proxy ? 1 : 0

  db_proxy_name = aws_db_proxy.main[0].name

  connection_pool_config {
    max_connections_percent      = 100
    max_idle_connections_percent = 50
    connection_borrow_timeout    = 120
  }
}

# RDS Proxy Target for Aurora
resource "aws_db_proxy_target" "aurora" {
  count = local.rds_enabled && var.rds.proxy && local.is_aurora ? 1 : 0

  db_proxy_name         = aws_db_proxy.main[0].name
  target_group_name     = aws_db_proxy_default_target_group.main[0].name
  db_cluster_identifier = aws_rds_cluster.main[0].cluster_identifier
}

# RDS Proxy Target for PostgreSQL
resource "aws_db_proxy_target" "postgres" {
  count = local.rds_enabled && var.rds.proxy && local.is_postgres ? 1 : 0

  db_proxy_name          = aws_db_proxy.main[0].name
  target_group_name      = aws_db_proxy_default_target_group.main[0].name
  db_instance_identifier = aws_db_instance.main[0].identifier
}

# Outputs for RDS
output "rds_endpoint" {
  value       = local.rds_enabled ? (local.is_aurora ? aws_rds_cluster.main[0].endpoint : aws_db_instance.main[0].endpoint) : null
  description = "RDS database endpoint"
}

output "rds_reader_endpoint" {
  value       = local.rds_enabled && local.is_aurora ? aws_rds_cluster.main[0].reader_endpoint : null
  description = "Aurora cluster reader endpoint (Aurora only)"
}

output "rds_proxy_endpoint" {
  value       = local.rds_enabled && var.rds.proxy ? aws_db_proxy.main[0].endpoint : null
  description = "RDS Proxy endpoint for database connections"
}

output "database_url_secret_name" {
  value       = local.rds_enabled ? aws_secretsmanager_secret.database_url[0].name : null
  description = "Name of the secret containing the database URLs"
}
