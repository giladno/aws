# Variables for the Lambda module
variable "function_name" {
  description = "Name of the Lambda function"
  type        = string
}

variable "global_config" {
  description = "Global Lambda configuration with defaults"
  type = any
}

variable "function_config" {
  description = "Lambda function configuration"
  type = object({
    source_dir  = string
    runtime     = optional(string, null)        # null = use global default
    handler     = optional(string, null)        # null = use global default
    timeout     = optional(number, null)        # null = use global default
    memory_size = optional(number, null)        # null = use global default
    environment = object({
      region    = optional(any, true)
      node      = optional(any, false)
      s3        = optional(any, null)
      database  = optional(any, null)
      variables = optional(map(string), {})
    })
    secrets = map(string)
    triggers = object({
      schedule = optional(object({
        enabled             = bool
        schedule_expression = string
        description         = string
        input               = optional(string, null)
      }), null)
      sqs = optional(object({
        enabled                 = bool
        queue_name              = optional(string, null)
        batch_size              = number
        maximum_batching_window = number
        queue_config = object({
          visibility_timeout_seconds = number
          message_retention_seconds  = number
          max_receive_count          = number
          delay_seconds              = number
          receive_wait_time_seconds  = number
          enable_dlq                 = bool
        })
      }), null)
      s3 = optional(object({
        enabled       = bool
        events        = list(string)
        filter_prefix = string
        filter_suffix = string
      }), null)
      http = optional(object({
        enabled           = bool
        methods           = list(string)
        path_pattern      = optional(string, null)
        subdomain         = optional(string, null)
        cors              = any # CORS configuration: null = disabled, true = default settings, object = custom settings
        authorization     = string
        disable_http      = bool
        catch_all_enabled = bool
        alb               = bool
      }), null)
    })
    kms                     = optional(any, null) # KMS encryption: null = use global default, false = no encryption, true = AWS-managed KMS, "key-id" = customer-managed KMS
    monitoring              = optional(bool, null)   # null = use global default
    provisioned_concurrency = optional(number, null) # Provisioned concurrency executions (null = use global default)
    reserved_concurrency    = optional(number, null) # Reserved concurrency limit (null = use global default)
    dead_letter_queue = optional(string, null) # SNS or SQS ARN for failed executions (null = use global default)
    version_management = optional(object({
      max_versions_to_keep = optional(number, 3)
      publish_versions     = optional(bool, false)
    }), null) # null = use global default
    log_retention_days = optional(number, null) # CloudWatch log retention days (null = use global default)
    network_access = optional(list(object({
      protocol = string       # "tcp", "udp", "icmp", or "all"
      ports    = list(number) # List of ports (e.g., [443, 80])
      cidrs    = list(string) # List of CIDR blocks (e.g., ["0.0.0.0/0"])
    })), []) # Function network access rules (merged with global rules)
    layers = optional(list(object({
      arn                 = optional(string, null)
      zip_file            = optional(string, null)
      name                = optional(string, null)
      description         = optional(string, "Lambda layer")
      compatible_runtimes = optional(list(string), null) # Compatible runtimes - will be set to default from main module if not specified
      license_info        = optional(string, null)
      max_versions        = optional(number, 5)
    })), [])
    # EFS mount configuration
    efs = optional(map(object({
      path = string                    # Mount path in Lambda function
      readonly = optional(bool, null)  # Override mount's readonly setting (null uses mount default)
    })), {})
  })
}

variable "config" {
  description = "Global configuration object"
  type = object({
    name                        = string
    aws_region                  = string
    dns_domain                  = optional(string, null)
    subdomain_routing_allowed   = optional(bool, true)
    cloudfront_enabled          = optional(bool, false)
    default_compatible_runtimes = list(string)
    tmp_directory               = string
    vpc = object({
      id         = string
      subnet_ids = list(string)
    })
    alb = optional(object({
      listener_arn      = string
      security_group_id = string
    }), null)
    s3_bucket_name           = optional(string, null)
    rds_enabled                   = optional(bool, false)
    database_secret_arn           = optional(string, null)
    lambda_shared_security_group_id = optional(string, null)
    # EFS configuration
    efs_enabled = optional(bool, false)
    efs_access_points = optional(map(string), {})  # mount_name -> access_point_arn
    common_tags                   = map(string)
  })
}

variable "lambda_role_arn" {
  description = "IAM role ARN for the Lambda function"
  type        = string
}

variable "monitoring_config" {
  description = "Monitoring configuration"
  type = object({
    enabled = bool
    sns_topics = object({
      critical_alerts_arn = string
      warning_alerts_arn  = string
    })
    lambda_alarms = object({
      error_rate_threshold = number
      duration_threshold   = number
      throttle_threshold   = number
      evaluation_periods   = number
    })
  })
  default = {
    enabled = false
    sns_topics = {
      critical_alerts_arn = ""
      warning_alerts_arn  = ""
    }
    lambda_alarms = {
      error_rate_threshold = 5
      duration_threshold   = 10000
      throttle_threshold   = 5
      evaluation_periods   = 2
    }
  }
}
