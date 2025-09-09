# Auto Scaling Target
resource "aws_appautoscaling_target" "service" {
  max_capacity       = var.service_config.max_capacity
  min_capacity       = var.service_config.min_capacity
  resource_id        = "service/${var.config.ecs.cluster_name}/${local.ecs_service.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"

  tags = var.config.common_tags
}

# Auto Scaling Policy - CPU
resource "aws_appautoscaling_policy" "service_cpu" {
  name               = "${var.config.name}-${var.service_name}-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.service.resource_id
  scalable_dimension = aws_appautoscaling_target.service.scalable_dimension
  service_namespace  = aws_appautoscaling_target.service.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value = var.service_config.target_cpu_utilization
  }
}

# Auto Scaling Policy - Memory
resource "aws_appautoscaling_policy" "service_memory" {
  name               = "${var.config.name}-${var.service_name}-memory-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.service.resource_id
  scalable_dimension = aws_appautoscaling_target.service.scalable_dimension
  service_namespace  = aws_appautoscaling_target.service.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
    target_value = var.service_config.target_memory_utilization
  }
}