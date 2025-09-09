# ALB Target Group (only when ALB exists globally - main module decides this)
resource "aws_lb_target_group" "service" {
  count = var.config.alb != null && var.service_config.http != null ? 1 : 0

  name        = "${var.config.name}-${var.service_name}-tg"
  port        = var.service_config.http.port
  protocol    = "HTTP"
  vpc_id      = var.config.vpc.id
  target_type = "ip"

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    path                = var.service_config.http.health_check_path
    matcher             = var.service_config.http.health_check_matcher != null ? var.service_config.http.health_check_matcher : "200-299"
    port                = "traffic-port"
    protocol            = "HTTP"
  }

  tags = merge(var.config.common_tags, {
    Name = "${var.config.name}-${var.service_name}-tg"
  })
}

# ALB Listener Rule for Path-based Routing
resource "aws_lb_listener_rule" "service_path" {
  # Use path-based routing when:
  # 1. ALB exists (main infrastructure level), AND
  # 2. HTTP service exists, AND
  # 3. Path pattern is specified, OR
  # 4. Subdomain is specified but subdomain routing is not allowed (DNS domain is already a subdomain)
  count = var.config.alb != null && var.service_config.http != null && (var.service_config.http.path_pattern != null || (var.service_config.http.subdomain != null && !var.config.subdomain_routing_allowed)) ? 1 : 0

  listener_arn = var.config.alb.listener_arn
  priority     = var.service_config.http.priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.service[0].arn
  }

  condition {
    path_pattern {
      values = [var.service_config.http.path_pattern != null ? var.service_config.http.path_pattern : "/*"]
    }
  }
}

# ALB Listener Rule for Host-based Routing (subdomain)
resource "aws_lb_listener_rule" "service_host" {
  # Use host-based routing only when:
  # 1. ALB exists (main infrastructure level), AND
  # 2. HTTP service exists, AND
  # 3. Subdomain is specified AND
  # 4. Subdomain routing is allowed (DNS domain is not already a subdomain) AND
  # 5. No path pattern is specified (path takes precedence)
  count = var.config.alb != null && var.service_config.http != null && var.service_config.http.subdomain != null && var.config.subdomain_routing_allowed && var.service_config.http.path_pattern == null ? 1 : 0

  listener_arn = var.config.alb.listener_arn
  priority     = var.service_config.http.priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.service[0].arn
  }

  condition {
    host_header {
      values = ["${var.service_config.http.subdomain}.${var.config.dns_domain}"]
    }
  }
}