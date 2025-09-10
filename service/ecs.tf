# ECS Task Definition
resource "aws_ecs_task_definition" "service" {
  family                   = "${var.config.name}-${var.service_name}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.service_config.task_cpu
  memory                   = var.service_config.task_memory
  execution_role_arn       = var.config.ecs.task_execution_role_arn
  task_role_arn            = var.config.ecs.task_role_arn

  # Runtime platform configuration
  dynamic "runtime_platform" {
    for_each = var.service_config.runtime != null ? [var.service_config.runtime] : []
    content {
      operating_system_family = runtime_platform.value.family
      cpu_architecture        = runtime_platform.value.architecture
    }
  }

  # Unified volume configuration
  dynamic "volume" {
    for_each = var.unified_mounts.volumes
    content {
      name = volume.key

      # EFS volume configuration
      dynamic "efs_volume_configuration" {
        for_each = volume.value.type == "efs" ? [1] : []
        content {
          file_system_id     = var.efs_config.file_system_id
          root_directory     = "/"
          transit_encryption = "ENABLED"

          authorization_config {
            access_point_id = split("/", var.efs_config.access_points[volume.key])[1]
            iam             = "ENABLED"
          }
        }
      }

      # Custom volume configuration (host path or ephemeral)
      host_path = volume.value.type == "custom" ? volume.value.host_path : null
    }
  }

  container_definitions = jsonencode(concat(
    # Additional containers (if defined) - added before the main service container
    var.service_config.containers != null ? [
      for container_name, container_config in var.service_config.containers : merge({
        name              = container_name
        image             = container_config.image
        essential         = container_config.essential
        entryPoint        = container_config.entryPoint
        command           = container_config.command
        cpu               = container_config.cpu
        memory            = container_config.memory
        memoryReservation = container_config.memoryReservation
        environment = [
          for key, value in container_config.environment : {
            name  = key
            value = value
          }
        ]
        secrets = [
          for key, value in container_config.secrets : {
            name      = key
            valueFrom = value
          }
        ]
        portMappings = container_config.portMappings
        healthCheck  = container_config.healthCheck
        logConfiguration = container_config.logConfiguration != null ? container_config.logConfiguration : {
          logDriver = "awslogs"
          options = {
            "awslogs-group"         = aws_cloudwatch_log_group.service.name
            "awslogs-region"        = var.config.aws_region
            "awslogs-stream-prefix" = "ecs-${container_name}"
          }
        }
        },
        # Add volume mounts for additional containers using same logic as main container
        container_config.volumes != null ? {
          mountPoints = concat(
            # EFS mounts (if any match volume names in EFS config)
            var.service_config.efs != null ? [
              for volume_name, mount_config in container_config.volumes : {
                sourceVolume = volume_name
                containerPath = (
                  mount_config == null ? "/mnt/${volume_name}" :
                  can(tostring(mount_config)) && mount_config != null ? tostring(mount_config) :
                  can(mount_config.path) ? mount_config.path : "/mnt/${volume_name}"
                )
                readOnly = (
                  mount_config == null ? false :
                  can(mount_config.readonly) && mount_config.readonly != null ? mount_config.readonly :
                  can(var.service_config.efs[volume_name]) ? (
                    var.service_config.efs[volume_name].readonly != null ?
                    var.service_config.efs[volume_name].readonly :
                    var.efs_config.mount_defaults[volume_name].readonly
                  ) : false
                )
              } if can(var.service_config.efs[volume_name])
            ] : [],
            # Volume mounts for sidecar containers (using new mount configuration)
            container_config.mount != null ? [
              for volume_name, mount_config in container_config.mount : {
                sourceVolume = volume_name
                containerPath = (
                  mount_config == null ? "/mnt/${volume_name}" :
                  can(tostring(mount_config)) && mount_config != null ? tostring(mount_config) :
                  can(mount_config.path) ? mount_config.path : "/mnt/${volume_name}"
                )
                readOnly = (
                  mount_config != null && can(mount_config.readonly) && mount_config.readonly != null ?
                  mount_config.readonly : false
                )
              } if can(var.service_config.volumes[volume_name])
            ] : []
          )
        } : {}
      )
    ] : [],
    # Main service container (always last)
    [merge({
      name       = var.service_name
      image      = var.service_config.image
      essential  = true
      command    = var.service_config.command != null ? var.service_config.command : null
      entryPoint = var.service_config.entrypoint != null ? var.service_config.entrypoint : null
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.service.name
          "awslogs-region"        = var.config.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }
      environment = var.environment_variables
      secrets     = var.secrets
      },
      # Add unified mount points
      length(var.unified_mounts.mount_points) > 0 ? {
        mountPoints = [
          for mount_name, mount_config in var.unified_mounts.mount_points : {
            sourceVolume  = mount_config.source_volume
            containerPath = mount_config.container_path
            readOnly      = mount_config.readonly
          }
        ]
      } : {},
      # Add port mappings conditionally for HTTP services
      {
        portMappings = var.service_config.http != null ? [
          {
            containerPort = var.service_config.http.port
            protocol      = "tcp"
          }
        ] : []
      },
      # Add health check for services with health_check configuration
      var.service_config.http != null && var.service_config.health_check != null ? {
        healthCheck = {
          command = [
            "CMD-SHELL",
            var.service_config.health_check.matcher == "any" ?
            "curl -f -s -X ${var.service_config.health_check.method} http://localhost:${var.service_config.http.port}${var.service_config.health_check.path} >/dev/null || wget --no-verbose --tries=1 --method=${var.service_config.health_check.method} --timeout=5 http://localhost:${var.service_config.http.port}${var.service_config.health_check.path} >/dev/null 2>&1 || exit 0" :
            "wget --no-verbose --tries=1 --method=${var.service_config.health_check.method} http://localhost:${var.service_config.http.port}${var.service_config.health_check.path} || exit 1"
          ]
          interval    = var.service_config.health_check.interval
          timeout     = var.service_config.health_check.timeout
          retries     = var.service_config.health_check.retries
          startPeriod = var.service_config.health_check.start_period
        }
      } : {}
    )]
  ))

  tags = var.config.common_tags
}

# ECS Service with automatic deployment (default)
resource "aws_ecs_service" "service_auto_deploy" {
  count = var.service_config.force_new_deployment ? 1 : 0

  name                 = "${var.config.name}-${var.service_name}"
  cluster              = var.config.ecs.cluster_id
  task_definition      = aws_ecs_task_definition.service.arn
  desired_count        = var.service_config.desired_count
  launch_type          = "FARGATE"
  force_new_deployment = true

  platform_version = "LATEST"

  network_configuration {
    security_groups = compact([
      aws_security_group.service.id,
      var.config.bastion_access_security_group_id,
      var.config.inter_service_security_group_id
    ])
    subnets          = var.config.vpc.subnet_ids
    assign_public_ip = false
  }

  # Load balancer configuration (only for HTTP services with target groups)
  dynamic "load_balancer" {
    for_each = length(aws_lb_target_group.service) > 0 ? [1] : []
    content {
      target_group_arn = aws_lb_target_group.service[0].arn
      container_name   = var.service_name
      container_port   = var.service_config.http.port
    }
  }

  # Health check grace period (only for services with load balancer)
  health_check_grace_period_seconds = length(aws_lb_target_group.service) > 0 ? var.service_config.health_check.grace_period : null

  # Service discovery configuration
  dynamic "service_registries" {
    for_each = var.config.service_discovery_service_arn != null ? [1] : []
    content {
      registry_arn = var.config.service_discovery_service_arn
    }
  }

  tags = var.config.common_tags

  lifecycle {
    ignore_changes = [desired_count]
  }
}

# ECS Service with manual deployment (when force_new_deployment = false)
resource "aws_ecs_service" "service_manual_deploy" {
  count = var.service_config.force_new_deployment ? 0 : 1

  name                 = "${var.config.name}-${var.service_name}"
  cluster              = var.config.ecs.cluster_id
  task_definition      = aws_ecs_task_definition.service.arn
  desired_count        = var.service_config.desired_count
  launch_type          = "FARGATE"
  force_new_deployment = false

  platform_version = "LATEST"

  network_configuration {
    security_groups = compact([
      aws_security_group.service.id,
      var.config.bastion_access_security_group_id,
      var.config.inter_service_security_group_id
    ])
    subnets          = var.config.vpc.subnet_ids
    assign_public_ip = false
  }

  # Load balancer configuration (only for HTTP services with target groups)
  dynamic "load_balancer" {
    for_each = length(aws_lb_target_group.service) > 0 ? [1] : []
    content {
      target_group_arn = aws_lb_target_group.service[0].arn
      container_name   = var.service_name
      container_port   = var.service_config.http.port
    }
  }

  # Health check grace period (only for services with load balancer)
  health_check_grace_period_seconds = length(aws_lb_target_group.service) > 0 ? var.service_config.health_check.grace_period : null

  # Service discovery configuration
  dynamic "service_registries" {
    for_each = var.config.service_discovery_service_arn != null ? [1] : []
    content {
      registry_arn = var.config.service_discovery_service_arn
    }
  }

  tags = var.config.common_tags

  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }
}
