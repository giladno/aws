# Services - using the generic service module
module "services" {
  source = "./service"

  for_each = local.services_unified_enabled

  service_name = each.key
  service_config = merge(each.value, {
    # Use built ECR image if source is specified, otherwise use provided image
    image = local.service_images[each.key]
  })

  # Configuration object with all necessary data
  config = {
    name                      = var.name
    aws_region                = var.aws_region
    dns_domain                = var.dns.domain != null ? var.dns.domain : null
    subdomain_routing_allowed = local.subdomain_routing_allowed

    vpc = {
      id         = aws_vpc.main.id
      subnet_ids = aws_subnet.private[*].id
      cidr_block = aws_vpc.main.cidr_block
    }

    ecs = {
      cluster_id              = aws_ecs_cluster.main.id
      cluster_name            = aws_ecs_cluster.main.name
      task_execution_role_arn = aws_iam_role.ecs_task_execution.arn
      task_role_arn           = local.service_role_map[each.key]
    }

    alb = local.alb_enabled ? {
      listener_arn      = aws_lb_listener.https[0].arn
      security_group_id = aws_security_group.alb[0].id
    } : null

    # RDS configuration for database access
    rds_enabled           = local.rds_enabled
    rds_security_group_id = local.rds_enabled ? aws_security_group.rds[0].id : null

    # Bastion access security group (services can optionally use this)
    bastion_access_security_group_id = local.bastion_enabled && length(var.services) > 0 ? aws_security_group.ecs_bastion_access[0].id : null

    # Logging configuration for CloudWatch log groups
    logging_kms = var.logging.kms

    # Service discovery configuration
    service_discovery_service_arn = contains(keys(local.services_with_local_dns), each.key) ? aws_service_discovery_service.services[each.key].arn : null

    # Inter-service communication security group
    inter_service_security_group_id = local.has_local_services ? aws_security_group.ecs_inter_service[0].id : null

    common_tags = local.common_tags
  }

  # Pass EFS configuration to service modules
  efs_config = var.efs.enabled ? {
    file_system_id = aws_efs_file_system.main[0].id
    access_points = {
      for mount_name, access_point in aws_efs_access_point.mounts :
      mount_name => access_point.arn
    }
    mount_defaults = {
      for mount_name, mount_config in var.efs.mounts :
      mount_name => {
        readonly = mount_config.readonly != null ? mount_config.readonly : false
      }
    }
    security_group_id = aws_security_group.efs[0].id
    } : {
    file_system_id    = null
    access_points     = {}
    mount_defaults    = {}
    security_group_id = null
  }

  # Use shared environment module (without database processing)
  environment_variables = module.service_environment[each.key].environment_variables
  secrets               = [
    for env_var_name, secret_ref in each.value.enhanced_secrets : {
      name      = env_var_name
      valueFrom = secret_ref
    }
  ]

  # Pass unified mount configuration
  unified_mounts = each.value.unified_mounts

  # Ensure Docker images are built before creating services
  depends_on = [null_resource.docker_build]
}

# Shared security group for ECS inter-service communication
resource "aws_security_group" "ecs_inter_service" {
  count = local.has_local_services ? 1 : 0

  name_prefix = "${var.name}-ecs-inter-service-"
  vpc_id      = aws_vpc.main.id
  description = "Security group for ECS inter-service communication when local services exist"

  # Allow ingress from other services in this security group on HTTP
  ingress {
    from_port = 80
    to_port   = 80
    protocol  = "tcp"
    self      = true
    description = "Inter-service communication HTTP"
  }

  # Allow ingress from other services in this security group on HTTPS
  ingress {
    from_port = 443
    to_port   = 443
    protocol  = "tcp"
    self      = true
    description = "Inter-service communication HTTPS"
  }

  # Allow ingress from other services in this security group on high ports (1024-65535)
  ingress {
    from_port = 1024
    to_port   = 65535
    protocol  = "tcp"
    self      = true
    description = "Inter-service communication high ports"
  }

  # Allow egress to other services in this security group on HTTP
  egress {
    from_port = 80
    to_port   = 80
    protocol  = "tcp"
    self      = true
    description = "Inter-service communication HTTP"
  }

  # Allow egress to other services in this security group on HTTPS
  egress {
    from_port = 443
    to_port   = 443
    protocol  = "tcp"
    self      = true
    description = "Inter-service communication HTTPS"
  }

  # Allow egress to other services in this security group on high ports (1024-65535)
  egress {
    from_port = 1024
    to_port   = 65535
    protocol  = "tcp"
    self      = true
    description = "Inter-service communication high ports"
  }

  tags = merge(local.common_tags, {
    Name = "${var.name}-ecs-inter-service-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# Add EFS egress rules for services that use EFS
resource "aws_security_group_rule" "service_to_efs_egress" {
  for_each = local.services_with_efs

  type                     = "egress"
  from_port                = 2049
  to_port                  = 2049
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.efs[0].id
  security_group_id        = module.services[each.key].security_group_id
  description              = "EFS access for service ${each.key}"
}

# Data sources for enhanced secrets to get correct ARNs with AWS-generated suffixes
data "aws_secretsmanager_secret" "enhanced_secrets" {
  for_each = local.all_enhanced_secret_names
  name = each.value
}

# Simplified ARN mapping - secrets are already processed with proper ARNs in global locals (defined in locals.tf)
locals {
  services_enhanced_secret_arns = {
    for service_name, service_config in local.services_unified :
    service_name => {
      for env_var_name, secret_arn in service_config.enhanced_secrets :
      # Extract base ARN (everything before the JSON key part)
      env_var_name => startswith(secret_arn, "arn:aws:secretsmanager:") ?
        join(":", slice(split(":", secret_arn), 0, 6)) : secret_arn
    }
  }
}

# Environment configuration for services using shared module (database config removed)
module "service_environment" {
  source = "./modules/environment"

  for_each = var.services

  service_name = each.key
  # Remove database from environment config - it's now handled via secrets
  environment_config = {
    region    = try(each.value.environment.region, null)
    node      = try(each.value.environment.node, null)
    s3        = try(each.value.environment.s3, null)
    variables = try(each.value.environment.variables, {})
  }
  secrets_config = {} # Secrets are now handled at the global level

  global_config = {
    name           = var.name
    aws_region     = var.aws_region
    environment    = var.environment
    s3_enabled     = local.s3_enabled
    s3_bucket_name = local.s3_enabled ? aws_s3_bucket.main[0].id : null
  }
}


# Output service information
output "services" {
  value = {
    for service_name, service_config in var.services : service_name => {
      target_group_arn  = module.services[service_name].target_group_arn
      security_group_id = module.services[service_name].security_group_id
      log_group_name    = module.services[service_name].log_group_name
    }
  }
  description = "Service information"
}
