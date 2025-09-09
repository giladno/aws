# Variables for the generic service module
variable "config" {
  description = "Complete configuration object"
  type = object({
    name                      = string
    aws_region                = string
    dns_domain                = optional(string, null) # Domain for subdomain routing
    subdomain_routing_allowed = optional(bool, true)   # Whether subdomain routing is allowed
    vpc = object({
      id         = string
      subnet_ids = list(string)
      cidr_block = string
    })
    ecs = object({
      cluster_id              = string
      cluster_name            = string
      task_execution_role_arn = string
      task_role_arn           = string
    })
    alb = object({
      listener_arn      = string
      security_group_id = string
    })
    # RDS configuration for database access
    rds_enabled         = optional(bool, false)
    rds_security_group_id = optional(string, null)
    # Bastion access security group
    bastion_access_security_group_id = optional(string, null)
    # Logging configuration for CloudWatch log groups
    logging_kms = any # KMS key for log group encryption
    # Service discovery configuration
    service_discovery_service_arn = optional(string, null)
    # Inter-service communication security group
    inter_service_security_group_id = optional(string, null)
    common_tags = map(string)
  })
}

variable "service_name" {
  description = "Name of the service (e.g., 'auth', 'rest', 'storage')"
}

variable "service_config" {
  description = "Service-specific configuration"
}

# Note: path_pattern and health_check_path are now part of service_config.http

variable "environment_variables" {
  description = "Environment variables for the container"
}

variable "secrets" {
  description = "Secrets for the container"
}

variable "efs_config" {
  description = "EFS configuration passed from main module"
  type = object({
    file_system_id = optional(string)
    access_points = optional(map(string), {})  # mount_name -> access_point_arn
    mount_defaults = optional(map(object({     # mount_name -> default config
      readonly = bool
    })), {})
    security_group_id = optional(string)
  })
  default = {
    access_points = {}
    mount_defaults = {}
  }
}

variable "unified_mounts" {
  description = "Unified mount configuration from main locals"
  type = object({
    volumes = map(object({
      type = string # "efs" or "custom"
      efs_config = optional(object({
        path = string
        readonly = optional(bool, false)
      }))
      host_path = optional(string)
    }))
    mount_points = map(object({
      container_path = string
      readonly = bool
      source_volume = string
    }))
  })
  default = {
    volumes = {}
    mount_points = {}
  }
}