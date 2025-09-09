# ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = "${var.name}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = local.common_tags
}
# IAM Role for ECS Task Execution
resource "aws_iam_role" "ecs_task_execution" {
  name = "${var.name}-ecs-task-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  tags = local.common_tags
}

# IAM Role Policy Attachment for ECS Task Execution
resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Per-service IAM Policy for ECS Task Execution to access specific secrets
resource "aws_iam_role_policy" "ecs_task_execution_secrets" {
  for_each = {
    for service_name, service_config in var.services : service_name => service_config
    if length(keys(service_config.secrets)) > 0 || service_config.environment.database != null
  }

  name = "${var.name}-ecs-task-execution-secrets-${each.key}"
  role = aws_iam_role.ecs_task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = [
          # All secrets are now in proper ARN format - just extract base ARN and add wildcard
          for secret_arn in values(local.services_unified_enabled[each.key].enhanced_secrets) :
          "${join(":", slice(split(":", secret_arn), 0, 6))}*"
        ]
      }
    ]
  })
}

# IAM Role for ECS Tasks (runtime permissions)
resource "aws_iam_role" "ecs_task" {
  name = "${var.name}-ecs-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  tags = local.common_tags
}
# Security Group for Application Load Balancer
resource "aws_security_group" "alb" {
  count = local.alb_config.enabled ? 1 : 0

  name_prefix = "${var.name}-alb-"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP"
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All outbound traffic"
  }

  tags = merge(local.common_tags, {
    Name = "${var.name}-alb-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# Application Load Balancer
resource "aws_lb" "main" {
  count = local.alb_config.enabled ? 1 : 0

  name               = "${var.name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb[0].id]
  subnets            = aws_subnet.public[*].id

  enable_deletion_protection       = var.alb.deletion_protection
  enable_http2                     = var.alb.enable_http2
  enable_cross_zone_load_balancing = true
  idle_timeout                     = var.alb.idle_timeout
  drop_invalid_header_fields       = var.alb.drop_invalid_headers

  tags = merge(local.common_tags, {
    Name = "${var.name}-alb"
  })
}

# ALB Listener for HTTP (redirect to HTTPS)
resource "aws_lb_listener" "main" {
  count = local.alb_config.enabled ? 1 : 0

  load_balancer_arn = aws_lb.main[0].arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  tags = local.common_tags
}

# ALB Listener for HTTPS
resource "aws_lb_listener" "https" {
  count = local.alb_config.enabled ? 1 : 0

  load_balancer_arn = aws_lb.main[0].arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = var.alb.ssl_policy
  certificate_arn   = var.dns.domain != null ? aws_acm_certificate_validation.main[0].certificate_arn : null

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "Service not found"
      status_code  = "404"
    }
  }

  tags = local.common_tags
}

# ALB Listener Rule for WWW redirect (only for top-level domains when enabled)
resource "aws_lb_listener_rule" "www_redirect" {
  count        = local.alb_config.needs_www_redirect ? 1 : 0
  listener_arn = aws_lb_listener.https[0].arn
  priority     = 50 # Higher priority than service rules

  action {
    type = "redirect"

    redirect {
      protocol    = "HTTPS"
      port        = "443"
      host        = var.dns.domain
      path        = "/#{path}"
      query       = "#{query}"
      status_code = "HTTP_301"
    }
  }

  condition {
    host_header {
      values = ["www.${var.dns.domain}"]
    }
  }

  tags = local.common_tags
}
