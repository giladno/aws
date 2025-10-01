
# Project Configuration
variable "name" {
  description = "Name of the project for resource naming (will be used as prefix for all resources)"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.name)) && length(var.name) <= 32
    error_message = "Name must contain only lowercase letters, numbers, and hyphens, and be 32 characters or less."
  }
}

# Environment Configuration
variable "environment" {
  description = "Environment name (e.g., dev, staging, production)"
  type        = string
  default     = "production"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.environment)) && length(var.environment) <= 16
    error_message = "Environment must contain only lowercase letters, numbers, and hyphens, and be 16 characters or less."
  }
}

# AWS Region Configuration
variable "aws_region" {
  description = "AWS region for resources"
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.aws_region))
    error_message = "AWS region must be a valid AWS region format (e.g., us-east-1, eu-west-1)."
  }
}

# DNS Configuration
variable "dns" {
  description = "DNS configuration - set domain to enable Route53 and ACM certificate"
  type = object({
    domain       = optional(string, null) # Set to your domain name to enable DNS and SSL
    www_redirect = optional(bool, null)   # Enable www to root domain redirect (auto-detects based on ALB usage if null)
    alb          = optional(bool, false)  # Force ALB creation for DNS redirect functionality
  })
  default = {}

  validation {
    condition = (
      var.dns.www_redirect == null ||
      !var.dns.www_redirect ||
      (var.dns.domain != null && length(split(".", var.dns.domain)) == 2)
    )
    error_message = "WWW redirect can only be enabled on top-level domains (e.g., 'example.com'), not subdomains (e.g., 'api.example.com')."
  }
}

# VPC Configuration
variable "vpc" {
  description = "VPC configuration with production-grade defaults"
  type = object({
    # Core VPC settings
    cidr_block                       = optional(string, "10.0.0.0/16")
    enable_dns_hostnames             = optional(bool, true)
    enable_dns_support               = optional(bool, true)
    instance_tenancy                 = optional(string, "default")
    assign_generated_ipv6_cidr_block = optional(bool, false)

    # Availability zones - defaults to first 3 AZs if not specified
    availability_zones = optional(list(string), [])

    # Public subnets configuration
    public_subnets = optional(object({
      enabled                         = optional(bool, true)
      cidrs                           = optional(list(string), ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"])
      names                           = optional(list(string), [])
      map_public_ip_on_launch         = optional(bool, true)
      assign_ipv6_address_on_creation = optional(bool, false)
    }), {})

    # Private subnets configuration
    private_subnets = optional(object({
      enabled                         = optional(bool, true)
      cidrs                           = optional(list(string), ["10.0.10.0/24", "10.0.20.0/24", "10.0.30.0/24"])
      names                           = optional(list(string), [])
      assign_ipv6_address_on_creation = optional(bool, false)
    }), {})

    # Database subnets configuration (isolated private subnets)
    # Defaults to enabled when RDS is enabled, disabled otherwise
    database_subnets = optional(object({
      enabled = optional(bool, null) # null = auto-detect based on RDS usage
      cidrs   = optional(list(string), ["10.0.100.0/24", "10.0.101.0/24", "10.0.102.0/24"])
      names   = optional(list(string), [])
    }), {})

    # Internet Gateway
    internet_gateway = optional(object({
      enabled = optional(bool, true)
      tags    = optional(map(string), {})
    }), {})

    # NAT Gateway configuration
    nat_gateway = optional(object({
      enabled                = optional(bool, true)
      single_nat_gateway     = optional(bool, false) # false = one per AZ (HA), true = single (cost savings)
      one_nat_gateway_per_az = optional(bool, true)  # Ignored if single_nat_gateway is true
      reuse_nat_ips          = optional(bool, false) # Use existing EIPs
      external_nat_ip_ids    = optional(list(string), [])
    }), {})

    # VPC Endpoints configuration
    endpoints = optional(object({
      enabled = optional(bool, true)

      # Gateway endpoints (free)
      s3 = optional(object({
        enabled         = optional(bool, null) # null = auto-detect based on S3 usage
        route_table_ids = optional(list(string), [])
        policy          = optional(string, null)
      }), {})

      # Interface endpoints (paid)
      # Defaults to enabled when Fargate is enabled, disabled otherwise
      ecr_api = optional(object({
        enabled             = optional(bool, null) # null = auto-detect based on Fargate usage
        private_dns_enabled = optional(bool, true)
        subnet_ids          = optional(list(string), [])
        security_group_ids  = optional(list(string), [])
        policy              = optional(string, null)
      }), {})

      ecr_dkr = optional(object({
        enabled             = optional(bool, null) # null = auto-detect based on Fargate usage
        private_dns_enabled = optional(bool, true)
        subnet_ids          = optional(list(string), [])
        security_group_ids  = optional(list(string), [])
        policy              = optional(string, null)
      }), {})

      logs = optional(object({
        enabled             = optional(bool, null) # null = auto-detect based on Fargate and RDS usage
        private_dns_enabled = optional(bool, true)
        subnet_ids          = optional(list(string), [])
        security_group_ids  = optional(list(string), [])
        policy              = optional(string, null)
      }), {})

      secretsmanager = optional(object({
        enabled             = optional(bool, null) # null = auto-detect based on RDS, Fargate, and bastion usage
        private_dns_enabled = optional(bool, true)
        subnet_ids          = optional(list(string), [])
        security_group_ids  = optional(list(string), [])
        policy              = optional(string, null)
      }), {})

      kms = optional(object({
        enabled             = optional(bool, null) # null = auto-detect based on RDS/S3 encryption usage
        private_dns_enabled = optional(bool, true)
        subnet_ids          = optional(list(string), [])
        security_group_ids  = optional(list(string), [])
        policy              = optional(string, null)
      }), {})

      # Additional custom endpoints
      # Use this to add any other VPC endpoints you need
      endpoints = optional(map(object({
        service_name        = string
        vpc_endpoint_type   = optional(string, "Interface") # "Interface" or "Gateway"
        private_dns_enabled = optional(bool, true)
        subnet_ids          = optional(list(string), [])
        security_group_ids  = optional(list(string), [])
        route_table_ids     = optional(list(string), []) # For Gateway endpoints only
        policy              = optional(string, null)
      })), {})
    }), {})

    # Flow logs configuration
    flow_logs = optional(object({
      enabled                  = optional(bool, false)
      log_destination_type     = optional(string, "cloud-watch-logs") # "cloud-watch-logs" or "s3"
      log_destination          = optional(string, null)               # ARN of CloudWatch Log Group or S3 bucket
      iam_role_arn             = optional(string, null)               # For CloudWatch Logs
      traffic_type             = optional(string, "ALL")              # "ALL", "ACCEPT", "REJECT"
      log_format               = optional(string, null)               # Custom log format
      max_aggregation_interval = optional(number, 600)                # 60 or 600 seconds
      log_retention_days       = optional(number, 30)                 # CloudWatch log retention in days
      tags                     = optional(map(string), {})
    }), {})


    # Additional configuration
    bastion = optional(any, null) # Single bastion object, array of bastion objects, or null
    # Structure for each bastion object:
    # {
    #   name                = optional(string, "bastion")   # Name suffix for this bastion instance
    #   enabled             = optional(bool, true)          # Enable this bastion instance
    #   username            = optional(string, "bastion")   # SSH username
    #   instance_type       = optional(string, "t4g.micro") # ARM-based instance type
    #   allowed_cidr_blocks = list(string)                  # CIDR blocks allowed SSH access - REQUIRED for security
    #   subdomain           = optional(string, null)        # Optional subdomain (e.g., "bastion" -> bastion.domain.com)
    #   start_instance      = optional(bool, false)         # Whether to start the instance immediately
    #   public_key          = optional(string, null)        # Additional SSH public key to add alongside the generated one
    #   efs                 = optional(bool, true)          # Whether to mount EFS volumes on this bastion instance
    # }

    # Custom tags for VPC resources
    vpc_tags             = optional(map(string), {})
    public_subnet_tags   = optional(map(string), {})
    private_subnet_tags  = optional(map(string), {})
    database_subnet_tags = optional(map(string), {})
    igw_tags             = optional(map(string), {})
    nat_gateway_tags     = optional(map(string), {})
    nat_eip_tags         = optional(map(string), {})
  })

  default = {}

  validation {
    condition     = can(cidrhost(var.vpc.cidr_block, 0))
    error_message = "VPC CIDR block must be a valid IPv4 CIDR."
  }

  validation {
    condition     = contains(["default", "dedicated"], var.vpc.instance_tenancy)
    error_message = "Instance tenancy must be either 'default' or 'dedicated'."
  }


  validation {
    condition     = length(var.vpc.availability_zones) == 0 || length(var.vpc.availability_zones) >= 2
    error_message = "Must specify at least 2 availability zones if providing custom AZs."
  }

  validation {
    condition     = !var.vpc.public_subnets.enabled || length(var.vpc.public_subnets.cidrs) >= 1
    error_message = "If public subnets are enabled, must provide at least 1 CIDR block."
  }

  validation {
    condition     = !var.vpc.private_subnets.enabled || length(var.vpc.private_subnets.cidrs) >= 1
    error_message = "If private subnets are enabled, must provide at least 1 CIDR block."
  }

  validation {
    condition     = !var.vpc.database_subnets.enabled || length(var.vpc.database_subnets.cidrs) >= 2
    error_message = "If database subnets are enabled, must provide at least 2 CIDR blocks for RDS requirements."
  }

  validation {
    condition     = !var.vpc.nat_gateway.enabled || var.vpc.public_subnets.enabled
    error_message = "NAT Gateway requires public subnets to be enabled."
  }

  validation {
    condition     = length(var.vpc.public_subnets.names) == 0 || length(var.vpc.public_subnets.names) == length(var.vpc.public_subnets.cidrs)
    error_message = "If providing custom public subnet names, must provide same number as CIDR blocks."
  }

  validation {
    condition     = length(var.vpc.private_subnets.names) == 0 || length(var.vpc.private_subnets.names) == length(var.vpc.private_subnets.cidrs)
    error_message = "If providing custom private subnet names, must provide same number as CIDR blocks."
  }

  validation {
    condition     = length(var.vpc.database_subnets.names) == 0 || length(var.vpc.database_subnets.names) == length(var.vpc.database_subnets.cidrs)
    error_message = "If providing custom database subnet names, must provide same number as CIDR blocks."
  }

  validation {
    condition     = contains(["ALL", "ACCEPT", "REJECT"], var.vpc.flow_logs.traffic_type)
    error_message = "Flow logs traffic_type must be 'ALL', 'ACCEPT', or 'REJECT'."
  }

  validation {
    condition     = contains(["cloud-watch-logs", "s3"], var.vpc.flow_logs.log_destination_type)
    error_message = "Flow logs destination type must be 'cloud-watch-logs' or 's3'."
  }

  validation {
    condition     = contains([60, 600], var.vpc.flow_logs.max_aggregation_interval)
    error_message = "Flow logs max aggregation interval must be 60 or 600 seconds."
  }

  validation {
    condition = (
      var.vpc.bastion == null ||
      (
        # If bastion is a single object
        (
          can(var.vpc.bastion.name) &&
          (!lookup(var.vpc.bastion, "enabled", true) || length(lookup(var.vpc.bastion, "allowed_cidr_blocks", [])) > 0)
        ) ||
        # If bastion is an array of objects
        (
          can(length(var.vpc.bastion)) &&
          alltrue([
            for b in var.vpc.bastion :
            (!lookup(b, "enabled", true) || length(lookup(b, "allowed_cidr_blocks", [])) > 0)
          ])
        )
      )
    )
    error_message = "When bastion host is enabled, allowed_cidr_blocks must be specified for security."
  }
}

# EFS Configuration
variable "efs" {
  description = "EFS configuration"
  type = object({
    enabled = optional(bool, false)

    # EFS file system settings
    performance_mode                = optional(string, "generalPurpose") # or "maxIO"
    throughput_mode                 = optional(string, "provisioned")    # or "bursting"
    provisioned_throughput_in_mibps = optional(number, 10)
    kms                             = optional(any, true) # Encryption settings: true = AWS-managed KMS, false = no encryption, "arn:..." = customer-managed

    # Define reusable mount configurations
    mounts = optional(map(object({
      path        = string # EFS directory path
      permissions = optional(string, "755")
      owner_uid   = optional(number, 1001)
      owner_gid   = optional(number, 1001)
      readonly    = optional(bool, null) # Default readonly setting (null = false)
    })), {})
  })
  default = {
    enabled = false
    mounts  = {}
  }
}

# S3 Configuration
variable "s3" {
  description = "S3 configuration"
  type = object({
    enabled     = optional(bool, true)   # Enable S3 bucket creation
    bucket_name = optional(string, null) # Set to override default bucket naming
    versioning  = optional(bool, false)  # Enable versioning

    # CloudFront static files configuration
    public              = optional(string, "/public")    # Path prefix for static files, null to disable CloudFront origin
    spa                 = optional(any, null)            # SPA redirect target: string path (e.g., "index.html") or true (uses default_root_object), null to disable
    default_root_object = optional(string, "index.html") # CloudFront default root object

    # CORS configuration
    cors_allowed_origins = optional(list(string), []) # Explicit CORS origins when DNS domain is not configured

    # Encryption configuration
    # kms = null/false -> no encryption, true -> AWS-managed KMS, "AES256" -> S3-managed, "key-id" -> customer-managed KMS
    kms = optional(any, true)

    lifecycle_rules = optional(object({
      transition_to_ia_days           = optional(number, 30)
      transition_to_glacier_days      = optional(number, 90)
      expiration_days                 = optional(number, null)
      abort_incomplete_multipart_days = optional(number, 1)

      # Additional custom lifecycle rules
      rules = optional(list(object({
        id     = string
        status = optional(string, "Enabled")

        # Filter configuration
        filter = optional(object({
          prefix = optional(string, null)
          tags   = optional(map(string), {})
        }), {})

        # Transition rules
        transitions = optional(list(object({
          days          = number
          storage_class = string
        })), [])

        # Expiration configuration
        expiration_days = optional(number, null)

        # Multipart upload cleanup
        abort_incomplete_multipart_days = optional(number, 1)
      })), [])
    }), {})
  })
  default = {}

  validation {
    condition = (
      var.s3.spa == null ||
      can(tostring(var.s3.spa)) ||
      var.s3.spa == true
    )
    error_message = "S3 spa must be null (disabled), a string path (e.g., 'index.html'), or true (uses default_root_object)."
  }

  validation {
    condition = (
      var.s3.lifecycle_rules.transition_to_ia_days == null ||
      var.s3.lifecycle_rules.transition_to_ia_days >= 30
    )
    error_message = "S3 lifecycle transition to STANDARD_IA requires a minimum of 30 days."
  }
}

# RDS Configuration
variable "rds" {
  description = "RDS database configuration - supports Aurora PostgreSQL or standard PostgreSQL"
  type = object({
    enabled = optional(bool, false) # Enable RDS database creation

    # Database type configuration
    engine_type    = optional(string, "aurora-postgresql") # "aurora-postgresql" or "postgres"
    engine_version = optional(string, "17.5")              # Engine version

    # Database settings
    db_name  = optional(string, null) # Defaults to var.name if not specified
    username = optional(string, "postgres")

    # Aurora-specific configuration (ignored for standard postgres)
    aurora_config = optional(object({
      instance_count          = optional(number, 1)              # Number of Aurora instances
      instance_class          = optional(string, "db.r6g.large") # Instance class for non-serverless Aurora
      serverless_min_capacity = optional(number, 0.5)            # Minimum ACUs for Serverless v2
      serverless_max_capacity = optional(number, 1)              # Maximum ACUs for Serverless v2
      serverless_enabled      = optional(bool, true)             # Use Serverless v2 scaling
    }), {})

    # Standard PostgreSQL configuration (ignored for Aurora)
    postgres_config = optional(object({
      instance_class        = optional(string, "db.t4g.micro") # Instance size
      allocated_storage     = optional(number, 20)             # Storage in GB
      max_allocated_storage = optional(number, 100)            # Auto-scaling limit
      storage_type          = optional(string, "gp3")          # Storage type
      multi_az              = optional(bool, false)            # Multi-AZ deployment
    }), {})

    # Encryption configuration
    # kms = null/false -> no encryption, true -> AWS-managed KMS, "key-id" -> customer-managed KMS
    kms = optional(any, true)

    # Common configuration
    backup_retention_period      = optional(number, 7) # Backup retention days
    backup_window                = optional(string, "03:00-04:00")
    maintenance_window           = optional(string, "Sun:04:00-Sun:05:00")
    performance_insights_enabled = optional(bool, false) # Performance Insights
    log_retention_days           = optional(number, 7)   # CloudWatch log retention

    # Network and security
    proxy                       = optional(bool, false) # Enable RDS Proxy
    proxy_auth_secrets          = optional(list(string), []) # Additional secrets for RDS Proxy authentication (ARNs)
    iam_database_authentication = optional(bool, true)  # Enable IAM database authentication (Aurora only)
    skip_final_snapshot         = optional(bool, true)  # Skip final snapshot on destroy
    deletion_protection         = optional(bool, true)  # Enable deletion protection
    network_access = optional(object({
      cidrs = optional(list(string), []) # CIDR blocks allowed access to RDS on port 5432 from public internet (empty = public subnet only, no ingress)
    }), null)                            # null = private access only

    # Monitoring and maintenance
    monitoring_interval        = optional(number, 0)  # Enhanced monitoring interval
    auto_minor_version_upgrade = optional(bool, true) # Auto minor version upgrades

    # Parameter groups for custom database parameters (e.g., extensions)
    parameter_groups = optional(object({
      aurora_parameters   = optional(map(string), {}) # Aurora cluster parameters
      instance_parameters = optional(map(string), {}) # Instance-level parameters (both Aurora and standard PostgreSQL)
    }), {})

    # Tags
    tags = optional(map(string), {})
  })
  default = {}

  validation {
    condition     = contains(["aurora-postgresql", "postgres"], var.rds.engine_type)
    error_message = "Engine type must be either 'aurora-postgresql' or 'postgres'."
  }

  validation {
    condition     = var.rds.engine_type != "postgres" || var.rds.postgres_config.allocated_storage >= 20
    error_message = "Standard PostgreSQL requires at least 20GB of allocated storage."
  }

  validation {
    condition     = var.rds.backup_retention_period >= 0 && var.rds.backup_retention_period <= 35
    error_message = "Backup retention period must be between 0 and 35 days."
  }

}

# Logging Configuration
variable "logging" {
  description = "Global logging and CloudWatch configuration"
  type = object({
    # CloudWatch Logs encryption
    # kms = null/false -> no encryption, true -> AWS-managed KMS, "key-id" -> customer-managed KMS
    kms = optional(any, true)
  })
  default = {}
}

# Services Configuration
variable "services" {
  description = "ECS Fargate services configuration"
  type = map(object({
    # Service control
    enabled = optional(bool, true) # Enable/disable this service

    # Container configuration (mutually exclusive: either image OR source)
    image = optional(string, null) # Docker image (e.g., "nginx:latest")
    source = optional(object({
      dir        = string                         # Local source directory for building container image
      dockerfile = optional(string, "Dockerfile") # Dockerfile path relative to dir
      context    = optional(string, ".")          # Build context relative to dir
      target     = optional(string, null)         # Multi-stage build target
      build_args = optional(map(string), {})      # Docker build arguments
      ignore = optional(list(string), [           # Ignore patterns for build triggers (defaults to common patterns)
        ".DS_Store",
        ".env*",
        ".git/**",
        ".next/**",
        ".nuxt/**",
        ".pytest_cache/**",
        ".tox/**",
        ".venv/**",
        "*.log",
        "*.pyc",
        "*.pyd",
        "*.pyo",
        "__pycache__/**",
        "build/**",
        "coverage/**",
        "dist/**",
        "node_modules/**",
        "venv/**"
      ])
    }), null)

    # HTTP configuration - set this to expose service via ALB (similar to Lambda triggers.http)
    http = optional(object({
      port         = number                 # Port exposed by container (required when http is defined)
      subdomain    = optional(string, null) # Subdomain for host-based routing (e.g., "api" for api.domain.com)
      path_pattern = optional(string, null) # ALB path pattern for path-based routing (e.g., "/api/*")
      priority     = optional(number, 100)  # ALB listener rule priority

      # CORS configuration (for HTTP services that need it)
      cors = optional(object({
        enabled           = optional(bool, false) # Enable CORS headers
        allow_credentials = optional(bool, false) # Allow credentials
        allow_headers     = optional(list(string), ["Authorization", "Content-Type"])
        allow_methods     = optional(list(string), ["DELETE", "GET", "OPTIONS", "POST", "PUT"])
        allow_origins     = optional(list(string), ["*"]) # Allowed origins
        expose_headers    = optional(list(string), [])    # Exposed headers
        max_age           = optional(number, 86400)       # Preflight cache time (seconds)
      }), { enabled = false })
    }), null) # null = background task (no HTTP exposure)

    # Health check configuration - applies to both container and ALB health checks
    health_check = optional(object({
      path         = optional(string, "/")       # Health check path
      matcher      = optional(string, "200-299") # ALB health check response codes or "any" for container health checks
      method       = optional(string, "HEAD")    # HTTP method for health checks (HEAD, GET, OPTIONS, POST)
      interval     = optional(number, 30)        # Health check interval in seconds
      timeout      = optional(number, 5)         # Health check timeout in seconds
      retries      = optional(number, 3)         # Number of retries before marking unhealthy
      start_period = optional(number, 60)        # Grace period in seconds before health checks start
      grace_period = optional(number, 300)       # ECS service health check grace period
    }), {})                                      # Default health check configuration with individual field defaults

    # Resource allocation
    task_cpu    = optional(number, 256) # CPU units (256, 512, 1024, etc.)
    task_memory = optional(number, 512) # Memory in MB

    # Scaling configuration
    desired_count             = optional(number, 1)
    min_capacity              = optional(number, 1)
    max_capacity              = optional(number, 10)
    target_cpu_utilization    = optional(number, 70)
    target_memory_utilization = optional(number, 80)

    # Deployment configuration
    deployment_max_percent = optional(number, 200)
    deployment_min_percent = optional(number, 50)
    force_new_deployment   = optional(bool, true) # Force new deployment when task definition changes

    # Logging
    log_retention_days = optional(number, 30)

    # Monitoring configuration
    monitoring = optional(bool, true) # Enable CloudWatch alarms: ECS metrics (CPU/Memory/Tasks) + ALB metrics (if routed) + Log monitoring

    # Environment configuration
    environment = optional(object({
      # AWS region - true = "AWS_REGION", string = custom env var name (services only)
      region = optional(any, true) # bool or string, defaults to true

      # Node.js environment - true = "NODE_ENV" with project environment, string = "NODE_ENV" with custom value
      node = optional(any, false) # bool or string, defaults to false

      # S3 bucket access - true = "S3_BUCKET", string = custom env var name
      s3 = optional(any, null) # bool or string

      # Database access - true = "DATABASE_URL", string = custom env var name
      database = optional(any, null) # bool or string

      # Custom environment variables
      variables = optional(map(string), {})
    }), {})

    # Secrets configuration (key = env var name, value = secret name in AWS Secrets Manager)
    secrets = optional(map(string), {})

    # Network access control - flat list format like Lambda functions
    network_access = optional(any, null) # null = block all, true = allow all, list of rules = specific access
    # Rules format: [{ protocol = "tcp", ports = [443], cidrs = ["0.0.0.0/0"] }, ...]

    # Local DNS configuration for internal service discovery
    local = optional(any, null) # null = no local DNS, true = create "<service-name>.local", string = create "<string>.local"

    # Container command and entrypoint override
    command    = optional(list(string), null) # Override container command
    entrypoint = optional(list(string), null) # Override container entrypoint

    # Runtime platform configuration
    runtime = optional(object({
      family       = string # Operating system family (e.g., "LINUX", "WINDOWS_SERVER_2019_CORE")
      architecture = string # CPU architecture (e.g., "X86_64", "ARM64")
    }), null)

    # EFS configuration - key/value pairs where key is mount name from efs.mounts
    efs = optional(map(object({
      path     = string               # Mount path in container
      readonly = optional(bool, null) # Override mount's readonly setting (null uses mount default)
    })), {})

    # Volumes configuration - custom ECS task definition volumes
    # key = volume name, value = null | string | object({path = string})
    # - null: creates non-persistent data volume
    # - string: creates host path volume with the string as path
    # - object({path = string}): creates host path volume with configurable path
    volumes = optional(map(any), null)

    # Mount configuration - volume mounts for the main container
    # key = volume name (must exist in volumes or efs config), value = mount configuration
    mount = optional(map(any), null) # null | string (path) | object({path = string, readonly = bool})

    # Containers configuration - additional containers before the main service container
    # key = container name, value = container configuration object
    containers = optional(map(object({
      image             = string                       # Docker image for the container
      essential         = optional(bool, false)        # Whether container is essential (main container is always essential=true)
      entryPoint        = optional(list(string), null) # Container entry point
      command           = optional(list(string), null) # Container command
      cpu               = optional(number, null)       # CPU units for this container (subtracted from task total)
      memory            = optional(number, null)       # Memory in MB for this container (subtracted from task total)
      memoryReservation = optional(number, null)       # Soft memory limit in MB

      # Environment variables and secrets for this container
      environment = optional(map(string), {}) # Environment variables key/value pairs
      secrets     = optional(map(string), {}) # Secrets key = env var name, value = secret name

      # Volume mounts using same logic as main container
      # key = volume name (must exist in volumes or efs config), value = mount configuration
      volumes = optional(map(any), null) # null | string (path) | object({path = string, readonly = bool}) - DEPRECATED, use mount
      mount   = optional(map(any), null) # null | string (path) | object({path = string, readonly = bool}) - NEW

      # Port mappings for this container
      portMappings = optional(list(object({
        containerPort = number
        hostPort      = optional(number, null)
        protocol      = optional(string, "tcp")
      })), [])

      # Health check for this container
      healthCheck = optional(object({
        command     = list(string)         # Health check command
        interval    = optional(number, 30) # Health check interval in seconds
        timeout     = optional(number, 5)  # Health check timeout in seconds
        retries     = optional(number, 3)  # Number of retries
        startPeriod = optional(number, 0)  # Grace period in seconds
      }), null)

      # Logging configuration for this container
      logConfiguration = optional(object({
        logDriver = optional(string, "awslogs")
        options   = optional(map(string), {})
      }), null)
    })), null)

    # IAM permissions configuration
    permissions = optional(object({
      s3  = optional(bool, true)  # S3 bucket access (read/write/delete)
      ses = optional(bool, false) # SES email sending permissions
      statements = optional(list(object({
        effect    = string       # "Allow" or "Deny"
        actions   = list(string) # List of IAM actions
        resources = list(string) # List of resource ARNs
        condition = optional(object({
          test     = string
          variable = string
          values   = list(string)
        }), null)
      })), [])
    }), null)
  }))

  default = {}

  validation {
    condition = alltrue([
      for service_name, service in var.services : contains([256, 512, 1024, 2048, 4096], service.task_cpu)
    ])
    error_message = "Task CPU must be one of: 256, 512, 1024, 2048, 4096."
  }

  validation {
    condition = alltrue([
      for service_name, service in var.services : (
        service.task_cpu == 256 ? contains([512, 1024, 2048], service.task_memory) :
        service.task_cpu == 512 ? contains([1024, 2048, 3072, 4096], service.task_memory) :
        service.task_cpu == 1024 ? (service.task_memory >= 2048 && service.task_memory <= 8192) :
        service.task_cpu == 2048 ? (service.task_memory >= 4096 && service.task_memory <= 16384) :
        service.task_cpu == 4096 ? (service.task_memory >= 8192 && service.task_memory <= 30720) :
        false
      )
    ])
    error_message = "Invalid CPU/Memory combination. See AWS Fargate task definitions for valid combinations."
  }

  validation {
    condition = alltrue([
      for service_name, service in var.services : (
        service.http == null ||
        service.http.subdomain == null ||
        (var.dns.domain != null && length(split(".", var.dns.domain)) <= 2)
      )
    ])
    error_message = "Service subdomain routing is not allowed when DNS domain is already a subdomain (e.g., 'api.domain.com'). Use path_pattern instead."
  }

  validation {
    condition = alltrue([
      for service_name, service in var.services : (
        (service.image != null && service.source == null) ||
        (service.image == null && service.source != null)
      )
    ])
    error_message = "Each service must specify exactly one of 'image' or 'source', not both or neither."
  }

  validation {
    condition = alltrue([
      for service_name, service in var.services : (
        service.http == null ||
        (service.http.subdomain != null) != (service.http.path_pattern != null) ||
        (service.http.subdomain == null && service.http.path_pattern == null)
      )
    ])
    error_message = "Service HTTP config must specify either subdomain OR path_pattern for routing, not both. Or neither for catch-all routing."
  }
}


variable "tags" {
  description = "Tags to apply to all resources (will be merged with automatic tags)"
  type        = map(string)
  default     = {}
}

# ALB Configuration
variable "alb" {
  description = "Application Load Balancer configuration"
  type = object({
    ssl_policy           = optional(string, "ELBSecurityPolicy-TLS13-1-2-2021-06") # ALB SSL/TLS policy
    deletion_protection  = optional(bool, true)                                    # Enable deletion protection
    enable_http2         = optional(bool, true)                                    # Enable HTTP/2
    idle_timeout         = optional(number, 60)                                    # Connection idle timeout
    drop_invalid_headers = optional(bool, false)                                   # Drop invalid headers
  })
  default = {}

  validation {
    condition = contains([
      "ELBSecurityPolicy-TLS13-1-2-2021-06",
      "ELBSecurityPolicy-TLS13-1-2-Ext1-2021-06",
      "ELBSecurityPolicy-TLS13-1-2-Ext2-2021-06",
      "ELBSecurityPolicy-TLS13-1-1-2021-06"
    ], var.alb.ssl_policy)
    error_message = "SSL policy must be one of the supported TLS 1.3 policies."
  }
}

# CloudFront Configuration
variable "cloudfront" {
  description = "CloudFront distribution configuration"
  type = object({
    price_class               = optional(string, "PriceClass_100")    # Price class for global distribution
    minimum_protocol_version  = optional(string, "TLSv1.2_2021")      # Minimum TLS version
    ssl_support_method        = optional(string, "sni-only")          # SSL support method
    compress                  = optional(bool, true)                  # Enable compression
    default_ttl               = optional(number, 86400)               # Default TTL (1 day)
    max_ttl                   = optional(number, 31536000)            # Max TTL (1 year)
    min_ttl                   = optional(number, 0)                   # Min TTL
    viewer_protocol_policy    = optional(string, "redirect-to-https") # Viewer protocol policy
    allowed_methods           = optional(list(string), ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"])
    cached_methods            = optional(list(string), ["GET", "HEAD"]) # Cached methods
    geo_restriction_type      = optional(string, "none")                # Geographic restriction
    geo_restriction_locations = optional(list(string), [])              # Countries for geo restriction
  })
  default = {}

  validation {
    condition = contains([
      "PriceClass_All", "PriceClass_200", "PriceClass_100"
    ], var.cloudfront.price_class)
    error_message = "Price class must be PriceClass_All, PriceClass_200, or PriceClass_100."
  }

  validation {
    condition = contains([
      "none", "blacklist", "whitelist"
    ], var.cloudfront.geo_restriction_type)
    error_message = "Geo restriction type must be none, blacklist, or whitelist."
  }
}

# Monitoring Configuration
variable "monitoring" {
  description = "Monitoring and alerting configuration"
  type = object({
    # Global monitoring control
    enabled = optional(bool, true) # Enable/disable all monitoring resources

    # SNS notification settings
    sns_notifications = optional(object({
      critical_alerts_email = optional(any, null) # Email(s) for critical alerts - string or list of strings
      warning_alerts_email  = optional(any, null) # Email(s) for warning alerts - string or list of strings
    }), {})

    # CloudWatch Dashboard
    dashboard = optional(object({
      enabled = optional(bool, true) # Create CloudWatch dashboard
    }), {})

    # Alarm thresholds and settings
    alarms = optional(object({
      # RDS/Aurora alarms
      aurora_cpu_threshold          = optional(number, 80)  # CPU utilization threshold (%)
      aurora_connections_threshold  = optional(number, 200) # Database connections threshold
      aurora_cpu_evaluation_periods = optional(number, 2)   # Evaluation periods for CPU alarm
      aurora_cpu_period             = optional(number, 300) # Period in seconds for CPU alarm

      # ALB alarms
      alb_response_time_threshold          = optional(number, 2)  # Response time threshold (seconds)
      alb_5xx_error_threshold              = optional(number, 10) # 5xx error count threshold
      alb_response_time_evaluation_periods = optional(number, 2)  # Evaluation periods
      alb_5xx_evaluation_periods           = optional(number, 2)  # Evaluation periods

      # CloudFront alarms
      cloudfront_5xx_threshold          = optional(number, 5) # 5xx error rate threshold (%)
      cloudfront_5xx_evaluation_periods = optional(number, 2) # Evaluation periods

      # ECS Service alarms (applied per service when monitoring is enabled)
      ecs_cpu_threshold             = optional(number, 80)  # CPU utilization threshold (%)
      ecs_memory_threshold          = optional(number, 80)  # Memory utilization threshold (%)
      ecs_cpu_evaluation_periods    = optional(number, 2)   # Evaluation periods for ECS CPU
      ecs_memory_evaluation_periods = optional(number, 2)   # Evaluation periods for ECS memory
      ecs_alarm_period              = optional(number, 300) # Period in seconds for ECS alarms

      # Service health and availability alarms
      ecs_service_min_running_tasks = optional(number, 1) # Minimum running tasks before alarm
      alb_healthy_host_threshold    = optional(number, 1) # Minimum healthy targets before alarm
      alb_unhealthy_host_threshold  = optional(number, 0) # Maximum unhealthy targets before alarm

      # Lambda function alarms (applied to functions with monitoring = true)
      lambda_error_threshold    = optional(number, 5)     # Lambda error count threshold per 5 minutes
      lambda_duration_threshold = optional(number, 10000) # Lambda duration threshold in milliseconds
      lambda_throttle_threshold = optional(number, 5)     # Lambda throttle count threshold per 5 minutes

      # General alarm settings
      treat_missing_data = optional(string, "notBreaching") # How to treat missing data
    }), {})

    # Log retention settings
    log_retention = optional(object({
      default_retention_days = optional(number, 14) # Default log retention for services
    }), {})

    # Log monitoring settings
    log_monitoring = optional(object({
      enabled                  = optional(bool, true) # Enable log-based alarms
      error_threshold          = optional(number, 10) # Error count threshold per 5 minutes
      error_evaluation_periods = optional(number, 2)  # Evaluation periods for error alarms
      # Common error patterns to monitor
      error_patterns = optional(list(string), [
        "ERROR",
        "FATAL",
        "Exception",
        "error:",
        "failed",
        "timeout"
      ])
    }), {})
  })
  default = {}
}

# SES Configuration
variable "ses" {
  description = "SES (Simple Email Service) configuration"
  type = object({
    enabled = optional(bool, false) # Enable SES domain configuration

    # Domain verification settings
    domain_verification = optional(object({
      create_verification_record = optional(bool, true) # Create Route53 verification record
      create_dkim_records        = optional(bool, true) # Create DKIM records for authentication
    }), {})

    # Email sending configuration
    sending_config = optional(object({
      reputation_tracking_enabled = optional(bool, true)    # Enable reputation tracking
      delivery_options            = optional(string, "TLS") # TLS or Opportunistic
    }), {})

    # Configuration set for tracking (optional)
    configuration_set = optional(object({
      enabled                 = optional(bool, false) # Create configuration set
      reputation_tracking     = optional(bool, true)  # Track bounce/complaint reputation
      delivery_delay_tracking = optional(bool, false) # Track delivery delays
      open_tracking           = optional(bool, false) # Track email opens (requires HTML emails)
      click_tracking          = optional(bool, false) # Track link clicks
    }), {})

    # Bounce and complaint handling
    bounce_notifications = optional(object({
      bounce_topic    = optional(string, null) # SNS topic ARN for bounces (optional)
      complaint_topic = optional(string, null) # SNS topic ARN for complaints (optional)
      delivery_topic  = optional(string, null) # SNS topic ARN for delivery notifications (optional)
    }), {})

    # Verified email addresses (for non-production use)
    verified_emails = optional(list(string), []) # List of email addresses to verify

    # Tags
    tags = optional(map(string), {})
  })
  default = {}

  validation {
    condition     = var.ses.enabled == false || (var.ses.enabled == true && var.dns.domain != null)
    error_message = "SES requires DNS domain to be configured when enabled."
  }
}

# Lambda Configuration
variable "lambda" {
  description = "Lambda configuration"
  type = object({
    # Global lambda settings (apply to all functions unless overridden)
    runtime                 = optional(string, "nodejs22.x")   # Default runtime for all functions
    handler                 = optional(string, "main.handler") # Default handler for all functions
    timeout                 = optional(number, 30)             # Default timeout in seconds
    memory_size             = optional(number, 128)            # Default memory allocation in MB
    provisioned_concurrency = optional(number, null)           # Default provisioned concurrency (null = disabled)
    reserved_concurrency    = optional(number, null)           # Default reserved concurrency limit
    dead_letter_queue       = optional(string, null)           # Default dead letter queue ARN (null = no dead letter queue)
    version_management = optional(object({
      max_versions_to_keep = optional(number, 3)                # Maximum number of versions to keep (automatic pruning)
      publish_versions     = optional(bool, false)              # Always publish new versions
    }), { max_versions_to_keep = 3, publish_versions = false }) # Default version management
    kms                = optional(any, null)                    # Default KMS encryption (null = no encryption)
    log_retention_days = optional(number, 30)                   # Default CloudWatch log retention in days
    monitoring         = optional(bool, true)                   # Default monitoring enabled

    # Global configuration that merges with function-level settings
    environment = optional(object({
      # Node.js environment - true = "NODE_ENV" with project environment, string = "NODE_ENV" with custom value
      # Automatically enabled for Node.js runtimes (nodejs22.x, nodejs20.x, etc.)
      node = optional(any, null) # bool or string, defaults to auto-detect based on runtime

      # S3 bucket access - true = "S3_BUCKET", string = custom env var name
      s3 = optional(any, null) # bool or string

      # Database access - true = "DATABASE_URL", string = custom env var name
      database = optional(any, null) # bool or string

      # Custom environment variables
      variables = optional(map(string), {})
    }), {}) # Default global environment (merged with function environment)

    secrets = optional(map(string), {}) # Default global secrets (merged with function secrets)

    layers = optional(list(object({
      # Either provide an existing layer ARN, a zip file path, OR a directory to create a new layer
      arn                 = optional(string, null)           # Existing layer ARN
      zip_file            = optional(string, null)           # Path to zip file for layer creation
      dir                 = optional(string, null)           # Directory path to zip and create layer
      name                = optional(string, null)           # Layer name (required if zip_file or dir is provided)
      description         = optional(string, "Lambda layer") # Layer description
      compatible_runtimes = optional(list(string), null)     # Compatible runtimes (defaults to all current Lambda runtimes from local.lambda_compatible_runtimes if not specified)
      license_info        = optional(string, null)           # License information
      max_versions        = optional(number, 5)              # Maximum versions to keep for created layers
    })), [])                                                 # Default global layers (merged with function layers)

    network_access = optional(list(object({
      protocol = string       # "tcp", "udp", "icmp", or "all"
      ports    = list(number) # List of ports (e.g., [443, 80])
      cidrs    = list(string) # List of CIDR blocks (e.g., ["0.0.0.0/0"])
    })), [])                  # Default global network access rules (merged with function rules)

    # Global network access to ECS Fargate services - creates security group rules for Lambda to call ECS services
    fargate = optional(bool, false) # Global Fargate service access (enables Lambda-to-ECS communication)

    # Global EFS configuration - applies to all functions unless overridden
    efs = optional(map(object({
      path     = string               # Mount path in Lambda function
      readonly = optional(bool, null) # Override mount's readonly setting (null uses mount default)
    })), {})

    # Global permissions configuration (s3/fargate/ses override, statements merge)
    permissions = optional(object({
      s3      = optional(bool, false) # Global S3 bucket access (function overrides)
      fargate = optional(bool, false) # Global Fargate service permissions (function overrides)
      ses     = optional(bool, false) # Global SES email sending permissions (function overrides)
      statements = optional(list(object({
        effect    = string       # "Allow" or "Deny"
        actions   = list(string) # List of IAM actions
        resources = list(string) # List of resource ARNs
        condition = optional(object({
          test     = string
          variable = string
          values   = list(string)
        }), null)
      })), []) # Global IAM statements (merged with function statements)
    }), {})    # Default global permissions

    # Functions configuration
    functions = optional(map(object({
      # Function control
      enabled = optional(bool, true) # Enable/disable this function

      # Function configuration
      source_dir  = string                 # Local directory containing function code
      runtime     = optional(string, null) # Lambda runtime (null = use global default)
      handler     = optional(string, null) # Function handler (null = use global default)
      timeout     = optional(number, null) # Function timeout in seconds (null = use global default)
      memory_size = optional(number, null) # Memory allocation in MB (null = use global default)

      # Performance and deployment configuration
      layers = optional(list(object({
        # Either provide an existing layer ARN, a zip file path, OR a directory to create a new layer
        arn                 = optional(string, null)           # Existing layer ARN
        zip_file            = optional(string, null)           # Path to zip file for layer creation
        dir                 = optional(string, null)           # Directory path to zip and create layer
        name                = optional(string, null)           # Layer name (required if zip_file or dir is provided)
        description         = optional(string, "Lambda layer") # Layer description
        compatible_runtimes = optional(list(string), null)     # Compatible runtimes (defaults to all current Lambda runtimes from local.lambda_compatible_runtimes if not specified)
        license_info        = optional(string, null)           # License information
        max_versions        = optional(number, 5)              # Maximum versions to keep for created layers
      })), [])
      provisioned_concurrency = optional(number, null) # Provisioned concurrency executions (null = use global default)

      # Function configuration
      reserved_concurrency = optional(number, null) # Reserved concurrency limit (null = use global default)
      dead_letter_queue    = optional(string, null) # SNS or SQS ARN for failed executions (null = use global default)

      # Version management
      version_management = optional(object({
        max_versions_to_keep = optional(number, 3)   # Maximum number of versions to keep (automatic pruning)
        publish_versions     = optional(bool, false) # Always publish new versions
      }), null)                                      # null = use global default

      # Environment configuration (Lambda-specific - no region needed)
      environment = optional(object({
        # Node.js environment - true = "NODE_ENV" with project environment, string = "NODE_ENV" with custom value
        # Automatically enabled for Node.js runtimes (nodejs22.x, nodejs20.x, etc.)
        node = optional(any, null) # bool or string, defaults to auto-detect based on runtime

        # S3 bucket access - true = "S3_BUCKET", string = custom env var name
        s3 = optional(any, null) # bool or string

        # Database access - true = "DATABASE_URL", string = custom env var name
        database = optional(any, null) # bool or string

        # Custom environment variables
        variables = optional(map(string), {})
      }), {})

      # Secrets configuration (array of key-value pairs)
      secrets = optional(map(string), {}) # key = env var name, value = secret name

      # IAM permissions configuration
      permissions = optional(object({
        s3      = optional(bool, true)  # S3 bucket access (read/write/delete)
        fargate = optional(bool, false) # ECS Fargate task execution (ecs:RunTask)
        ses     = optional(bool, false) # SES email sending permissions
        statements = optional(list(object({
          effect    = string       # "Allow" or "Deny"
          actions   = list(string) # List of IAM actions
          resources = list(string) # List of resource ARNs
          condition = optional(object({
            test     = string
            variable = string
            values   = list(string)
          }), null)
        })), [])
      }), null)

      # VPC configuration (optional)
      vpc_config = optional(object({
        subnet_ids         = optional(list(string), []) # Use private subnets if specified
        security_group_ids = optional(list(string), []) # Custom security groups
      }), null)

      # Network access control (merged with global network access)
      network_access = optional(list(object({
        protocol = string       # "tcp", "udp", "icmp", or "all"
        ports    = list(number) # List of ports (e.g., [443, 80])
        cidrs    = list(string) # List of CIDR blocks (e.g., ["0.0.0.0/0"])
      })), [])                  # Function network access rules (merged with global rules)

      # Network access to ECS Fargate services - creates security group rules for Lambda to call ECS services
      fargate = optional(bool, null) # Function-specific Fargate service access (null = use global default)

      # Function-specific EFS configuration - merges with global EFS config
      efs = optional(map(object({
        path     = string               # Mount path in Lambda function
        readonly = optional(bool, null) # Override mount's readonly setting (null uses mount default)
      })), {})

      # Encryption configuration
      # kms = null -> use global default, false -> no encryption, true -> AWS-managed KMS, "key-id" -> customer-managed KMS
      kms = optional(any, null) # null = use global default

      # Triggers configuration
      triggers = optional(object({
        # CloudWatch Events/EventBridge scheduled trigger
        schedule = optional(object({
          enabled             = optional(bool, true)
          schedule_expression = string # e.g., "rate(5 minutes)" or "cron(0 18 ? * MON-FRI *)"
          description         = optional(string, "Scheduled Lambda execution")
          input               = optional(string, null) # JSON input for the function
        }), null)

        # SQS trigger with queue creation
        sqs = optional(object({
          enabled                 = optional(bool, true)
          queue_name              = optional(string, null) # Optional queue name (defaults to function name)
          batch_size              = optional(number, 10)   # Messages per batch
          maximum_batching_window = optional(number, 0)    # Batching window in seconds

          # SQS Queue configuration (creates new queue)
          queue_config = object({
            visibility_timeout_seconds = optional(number, 30)     # Message visibility timeout
            message_retention_seconds  = optional(number, 345600) # 4 days default
            max_receive_count          = optional(number, 3)      # DLQ threshold
            delay_seconds              = optional(number, 0)      # Delivery delay
            receive_wait_time_seconds  = optional(number, 0)      # Long polling

            # Dead Letter Queue
            enable_dlq = optional(bool, true) # Create dead letter queue
          })
        }), null)

        # S3 trigger (always uses main S3 bucket)
        s3 = optional(object({
          enabled       = optional(bool, true)
          events        = optional(list(string), ["s3:ObjectCreated:*"]) # S3 events to trigger on
          filter_prefix = optional(string, "")                           # Object key prefix filter
          filter_suffix = optional(string, "")                           # Object key suffix filter
        }), null)

        # HTTP API Gateway trigger
        http = optional(object({
          enabled           = optional(bool, true)
          methods           = optional(list(string), ["GET", "POST"]) # HTTP methods (e.g., ["GET", "POST"])
          path_pattern      = optional(string, null)                  # Path-based routing (e.g., "/api/webhook")
          subdomain         = optional(string, null)                  # Subdomain routing (e.g., "api" for api.domain.com)
          cors              = optional(any, null)                     # CORS configuration: null = disabled, true = default settings, object = custom settings
          authorization     = optional(string, "NONE")                # "NONE", "AWS_IAM", "COGNITO"
          disable_http      = optional(bool, true)                    # Disable HTTP protocol (HTTPS only)
          catch_all_enabled = optional(bool, true)                    # Enable catch-all routing for path patterns/subdomains
          alb               = optional(bool, false)                   # Force ALB creation even with no services (enables HTTP->HTTPS redirect)

          # CloudFront caching configuration (only applies when CloudFront is enabled)
          cache = optional(object({
            enabled     = optional(bool, false)      # Enable caching for this Lambda function
            min_ttl     = optional(number, 0)        # Minimum TTL in seconds
            default_ttl = optional(number, 86400)    # Default TTL in seconds (24 hours)
            max_ttl     = optional(number, 31536000) # Maximum TTL in seconds (1 year)

            # Cache key configuration
            cache_key = optional(object({
              query_strings = optional(object({
                behavior = optional(string, "none")   # "none", "whitelist", "all"
                items    = optional(list(string), []) # Query string names when behavior = "whitelist"
              }), { behavior = "all" })               # Default: cache based on all query strings

              headers = optional(object({
                behavior = optional(string, "none")   # "none", "whitelist"
                items    = optional(list(string), []) # Header names when behavior = "whitelist"
              }), { behavior = "none" })              # Default: don't include headers in cache key

              cookies = optional(object({
                behavior = optional(string, "none")   # "none", "whitelist", "all"
                items    = optional(list(string), []) # Cookie names when behavior = "whitelist"
              }), { behavior = "none" })              # Default: don't include cookies in cache key
            }), {})
          }), { enabled = false }) # Default: no caching
        }), null)
      }), {})

      # Logging configuration
      log_retention_days = optional(number, null) # CloudWatch log retention in days (null = use global default)

      # Monitoring
      monitoring = optional(bool, null) # Enable Lambda monitoring and alarms (null = use global default)
    })), {})                            # Close functions map and set default empty
  })

  default = {
    runtime                 = "nodejs22.x"
    handler                 = "main.handler"
    timeout                 = 30
    memory_size             = 128
    provisioned_concurrency = null
    reserved_concurrency    = null
    dead_letter_queue       = null
    version_management = {
      max_versions_to_keep = 3
      publish_versions     = false
    }
    kms                = null
    log_retention_days = 30
    monitoring         = true
    environment = {
      node      = null
      s3        = null
      database  = null
      variables = {}
    }
    secrets        = {}
    layers         = []
    network_access = []
    functions      = {}
  }

  validation {
    condition = alltrue([
      for name, config in var.lambda.functions : (
        config.triggers.http != null ? (
          (config.triggers.http.path_pattern != null) != (config.triggers.http.subdomain != null)
        ) : true
      )
    ])
    error_message = "Lambda HTTP trigger must specify either path_pattern OR subdomain, not both."
  }

  validation {
    condition = alltrue([
      for name, config in var.lambda.functions : (
        config.triggers.http == null ||
        config.triggers.http.subdomain == null ||
        (var.dns.domain != null && length(split(".", var.dns.domain)) <= 2)
      )
    ])
    error_message = "Lambda subdomain routing is not allowed when DNS domain is already a subdomain (e.g., 'api.domain.com'). Use path_pattern instead."
  }

  validation {
    condition = alltrue(flatten([
      for name, config in var.lambda.functions : [
        for layer in config.layers : (
          (layer.arn != null && layer.zip_file == null && layer.dir == null) ||
          (layer.arn == null && layer.zip_file != null && layer.dir == null && layer.name != null) ||
          (layer.arn == null && layer.zip_file == null && layer.dir != null && layer.name != null)
        )
      ]
    ]))
    error_message = "Each Lambda layer must specify exactly one of: 'arn' (for existing layers), 'zip_file' and 'name' (for zip-based layers), or 'dir' and 'name' (for directory-based layers)."
  }

  validation {
    condition = alltrue([
      for name, config in var.lambda.functions : (
        config.triggers.sqs != null && config.triggers.sqs.enabled ?
        config.triggers.sqs.queue_config != null : true
      )
    ])
    error_message = "SQS trigger requires queue_config to be specified."
  }
}

# Temporary Directory Configuration
variable "tmp" {
  description = "Temporary directory for build artifacts and intermediate files"
  type        = string
  default     = ".terraform/tmp"
}

# ECR Configuration
variable "ecr" {
  description = "ECR repository configuration for container image lifecycle management"
  type = object({
    # ECR lifecycle policy configuration
    lifecycle_policy = optional(object({
      enabled = optional(bool, true) # Enable lifecycle policy

      # Global defaults (apply to all services unless overridden in service-specific rules)
      global_defaults = optional(object({
        keep_count = optional(number, 10) # Default number of images to keep per service
      }), { keep_count = 10 })

      # Service-specific lifecycle policies
      # Map of service_name => configuration to override global defaults
      service_policies = optional(map(object({
        keep_count = number # Number of images to keep for this specific service
      })), {})
    }), { enabled = true, global_defaults = { keep_count = 10 }, service_policies = {} })

    # Additional ECR settings
    image_tag_mutability = optional(string, "MUTABLE") # "MUTABLE" or "IMMUTABLE"
    scan_on_push         = optional(bool, true)        # Enable image scanning
    encryption_type      = optional(string, "AES256")  # "AES256" or "KMS"
    kms_key              = optional(string, null)      # KMS key for encryption (when encryption_type = "KMS")
  })
  default = {}

  validation {
    condition     = contains(["MUTABLE", "IMMUTABLE"], var.ecr.image_tag_mutability)
    error_message = "ECR image tag mutability must be either 'MUTABLE' or 'IMMUTABLE'."
  }

  validation {
    condition     = contains(["AES256", "KMS"], var.ecr.encryption_type)
    error_message = "ECR encryption type must be either 'AES256' or 'KMS'."
  }

  validation {
    condition = (
      var.ecr.lifecycle_policy.global_defaults.keep_count >= 1 &&
      var.ecr.lifecycle_policy.global_defaults.keep_count <= 1000
    )
    error_message = "ECR global keep_count must be between 1 and 1000."
  }

  validation {
    condition = alltrue([
      for service_name, policy in var.ecr.lifecycle_policy.service_policies : (
        policy.keep_count >= 1 && policy.keep_count <= 1000
      )
    ])
    error_message = "ECR service-specific keep_count must be between 1 and 1000."
  }
}

# ================================
# LOCAL VALUES (COMPUTED CONFIGURATION)
# ================================

# All locals moved to locals.tf for unified processing
