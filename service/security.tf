# Security Group
resource "aws_security_group" "service" {
  name_prefix = "${var.config.name}-${var.service_name}-"
  vpc_id      = var.config.vpc.id

  # Ingress rule only for HTTP services with ALB
  dynamic "ingress" {
    for_each = var.service_config.http != null && var.config.alb != null ? [1] : []
    content {
      from_port       = var.service_config.http.port
      to_port         = var.service_config.http.port
      protocol        = "tcp"
      security_groups = [var.config.alb.security_group_id]
      description     = "HTTP from ALB"
    }
  }

  # Dynamic outbound rules based on network_access configuration (flat list format)
  dynamic "egress" {
    for_each = var.service_config.network_access == true ? [1] : []
    content {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = ["0.0.0.0/0"]
      description = "All outbound traffic (explicitly allowed)"
    }
  }

  dynamic "egress" {
    for_each = var.service_config.network_access != null && var.service_config.network_access != true ? var.service_config.network_access : []
    content {
      from_port   = length(egress.value.ports) == 1 ? egress.value.ports[0] : min(egress.value.ports...)
      to_port     = length(egress.value.ports) == 1 ? egress.value.ports[0] : max(egress.value.ports...)
      protocol    = egress.value.protocol
      cidr_blocks = egress.value.cidrs
      description = "Custom outbound rule"
    }
  }

  # Essential outbound access for ECS tasks (when not explicitly allowing all)
  dynamic "egress" {
    for_each = var.service_config.network_access != true ? [1] : []
    content {
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = [var.config.vpc.cidr_block]
      description = "HTTPS to VPC endpoints"
    }
  }

  # Database access for services with database = true
  # Services need explicit security group rules to access RDS (similar to Lambda functions)
  dynamic "egress" {
    for_each = var.service_config.environment.database != null && var.service_config.environment.database != false && var.config.rds_enabled ? [1] : []
    content {
      from_port   = 5432
      to_port     = 5432
      protocol    = "tcp"
      cidr_blocks = [var.config.vpc.cidr_block]  # Use VPC CIDR instead of security group reference
      description = "PostgreSQL to RDS from service"
    }
  }


  tags = merge(var.config.common_tags, {
    Name = "${var.config.name}-${var.service_name}-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}