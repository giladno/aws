locals {
  # All supported Lambda runtimes
  lambda_compatible_runtimes = [
    "dotnet6", "dotnet8",
    "go1.x",
    "java8.al2", "java11", "java17", "java21",
    "nodejs18.x", "nodejs20.x", "nodejs22.x",
    "provided.al2", "provided.al2023",
    "python3.9", "python3.10", "python3.11", "python3.12", "python3.13",
    "ruby3.2", "ruby3.3"
  ]

  # Service detection and conditional defaults

  # Detect if services are enabled
  fargate_enabled = length(local.services_unified_enabled) > 0
  rds_enabled     = var.rds.enabled
  is_aurora       = local.rds_enabled && var.rds.engine_type == "aurora-postgresql"
  is_postgres     = local.rds_enabled && var.rds.engine_type == "postgres"
  s3_enabled      = var.s3.enabled
  ses_enabled     = var.ses.enabled
  # Normalize bastion configuration to an array
  bastion_configs = var.vpc.bastion == null ? [] : (
    # If it's already an array, use it directly
    can(length(var.vpc.bastion)) ? [
      for idx, config in var.vpc.bastion : merge({
        name                = lookup(config, "name", "bastion-${idx + 1}")
        enabled             = lookup(config, "enabled", true)
        username            = lookup(config, "username", "bastion")
        instance_type       = lookup(config, "instance_type", "t4g.micro")
        allowed_cidr_blocks = lookup(config, "allowed_cidr_blocks", [])
        subdomain           = lookup(config, "subdomain", null)
        start_instance      = lookup(config, "start_instance", false)
        public_key          = lookup(config, "public_key", null)
        efs                 = lookup(config, "efs", true)
      }, { index = idx })
    ] : [
      # If it's a single object, convert to array
      merge({
        name                = lookup(var.vpc.bastion, "name", "bastion")
        enabled             = lookup(var.vpc.bastion, "enabled", true)
        username            = lookup(var.vpc.bastion, "username", "bastion")
        instance_type       = lookup(var.vpc.bastion, "instance_type", "t4g.micro")
        allowed_cidr_blocks = lookup(var.vpc.bastion, "allowed_cidr_blocks", [])
        subdomain           = lookup(var.vpc.bastion, "subdomain", null)
        start_instance      = lookup(var.vpc.bastion, "start_instance", false)
        public_key          = lookup(var.vpc.bastion, "public_key", null)
        efs                 = lookup(var.vpc.bastion, "efs", true)
      }, { index = 0 })
    ]
  )

  # Filter enabled bastion instances
  bastion_configs_enabled = {
    for config in local.bastion_configs : config.name => config
    if config.enabled
  }

  bastion_enabled = length(local.bastion_configs_enabled) > 0

  # Detect if ECR is needed (any service uses source)
  ecr_enabled = anytrue([
    for name, config in local.services_unified_enabled :
    config.source != null
  ])

  # ECR service-specific lifecycle rules configuration
  ecr_service_lifecycle_rules = [
    for service_name in keys(local.services_unified_enabled) : {
      service_name = service_name
      keep_count   = lookup(var.ecr.lifecycle_policy.service_policies, service_name, var.ecr.lifecycle_policy.global_defaults).keep_count
    }
    if local.services_unified_enabled[service_name].source != null
  ]

  # DNS domain analysis
  subdomain_routing_allowed = var.dns.domain != null && (
    length(split(".", var.dns.domain)) == 2 || # Traditional: example.com
    length(split(".", var.dns.domain)) >= 3    # Full custom domain: api.example.com
  )

  # WWW redirect logic
  www_redirect_enabled = var.dns.www_redirect != null ? var.dns.www_redirect : (local.alb_enabled && local.subdomain_routing_allowed)

  # S3 SPA logic
  s3_spa_target = var.s3.spa == true ? var.s3.default_root_object : var.s3.spa

  # Conditional VPC endpoint defaults
  vpc_endpoints_defaults = {
    s3_enabled = var.vpc.endpoints.s3.enabled != null ? var.vpc.endpoints.s3.enabled : local.s3_enabled

    ecr_api_enabled = var.vpc.endpoints.ecr_api.enabled != null ? var.vpc.endpoints.ecr_api.enabled : local.fargate_enabled
    ecr_dkr_enabled = var.vpc.endpoints.ecr_dkr.enabled != null ? var.vpc.endpoints.ecr_dkr.enabled : local.fargate_enabled
    kms_enabled     = var.vpc.endpoints.kms.enabled != null ? var.vpc.endpoints.kms.enabled : (local.rds_enabled || local.s3_enabled)
  }

  # Database subnets default
  database_subnets_enabled = var.vpc.database_subnets.enabled != null ? var.vpc.database_subnets.enabled : local.rds_enabled

  # Computed database name
  computed_db_name = var.rds.db_name != null ? var.rds.db_name : replace(var.name, "-", "_")

  # Common tags
  common_tags = merge(var.tags, {
    Environment = var.environment
    Project     = var.name
    ManagedBy   = "terraform"
  })

  # Extract secret names for data source lookups
  all_service_secret_names = toset(compact(flatten([
    for service_name, service_config in var.services : [
      for secret_ref in values(try(service_config.secrets, {})) :
      length(split(":", secret_ref)) > 1 ? split(":", secret_ref)[0] : secret_ref
    ] if service_config.enabled
  ])))
  
  # Database secret names
  all_database_secret_names = toset(compact([
    for service_name, service_config in var.services :
    service_config.enabled && try(service_config.environment.database.secret, null) != null && !startswith(try(service_config.environment.database.secret, ""), "arn:aws:secretsmanager:") ?
      (length(split(":", service_config.environment.database.secret)) > 1 ? 
        split(":", service_config.environment.database.secret)[0] : 
        service_config.environment.database.secret) : null
  ]))
  
  # Lambda secrets
  all_lambda_secret_names = toset(compact(flatten([
    for function_name, function_config in var.lambda.functions : [
      for secret_ref in values(try(function_config.secrets, {})) :
      length(split(":", secret_ref)) > 1 ? split(":", secret_ref)[0] : secret_ref
    ] if function_config.enabled
  ])))
  
  # Combined secret names
  all_enhanced_secret_names = setunion(
    local.all_service_secret_names, 
    local.all_database_secret_names, 
    local.all_lambda_secret_names
  )

  # Lambda functions needing database
  lambda_functions_needing_database = local.lambda_needs_database

  # Services that need custom IAM roles
  services_with_custom_roles = {
    for name, config in local.services_unified_enabled : name => config
    if config.permissions != null
  }
  
  # Services that need S3 access
  services_needing_s3 = {
    for name, config in var.services : name => config
    if config.permissions != null && config.permissions.s3 && local.s3_enabled
  }
  
  # Services that need SES access
  services_needing_ses = {
    for name, config in var.services : name => config
    if config.permissions != null && config.permissions.ses && local.ses_enabled
  }
  
  # Services that need Aurora IAM auth
  services_needing_aurora_iam = {
    for name, config in var.services : name => config
    if config.environment.database != null && local.rds_enabled && local.is_aurora && var.rds.iam_database_authentication
  }
  
  # Services that need custom permissions (have statements defined)
  services_with_custom_statements = {
    for name, config in var.services : name => config
    if config.permissions != null && length(config.permissions.statements) > 0
  }
  
  # Lambda functions that need custom roles
  lambda_functions_with_custom_permissions = {
    for name, config in local.lambda_functions_enabled : name => config
    if config.permissions != var.lambda.permissions
  }
  
  # Lambda functions that need S3 access
  lambda_functions_needing_s3 = merge(
    # Functions with custom permissions that need S3
    {
      for name, config in local.lambda_functions_with_custom_permissions : name => config
      if config.permissions.s3 && local.s3_enabled
    },
    # Functions with default permissions but environment.s3 = true  
    {
      for name, config in local.lambda_functions_enabled : name => config
      if config.permissions == var.lambda.permissions && config.environment.s3 != null && local.s3_enabled
    }
  )
  
  # Lambda functions that need SES access
  lambda_functions_needing_ses = {
    for name, config in local.lambda_functions_with_custom_permissions : name => config
    if config.permissions.ses && local.ses_enabled
  }
  
  # Lambda functions that need Fargate access
  lambda_functions_needing_fargate = {
    for name, config in local.lambda_functions_with_custom_permissions : name => config
    if config.permissions.fargate && length(var.services) > 0
  }
  
  # Lambda functions that need Aurora IAM auth
  lambda_functions_needing_aurora_iam = {
    for name, config in local.lambda_functions_enabled : name => config
    if config.environment.database != null && config.environment.database != false && local.rds_enabled && local.is_aurora && var.rds.iam_database_authentication
  }
  
  # Lambda functions that need VPC access
  lambda_functions_needing_vpc = {
    for name, config in local.lambda_functions_with_custom_permissions : name => config
    if(config.environment.database != null && config.environment.database != false) ||
      length(config.enhanced_secrets) > 0 ||
      length(config.network_access) > 0
  }
  
  # Lambda functions with custom statements
  lambda_functions_with_custom_statements = {
    for name, config in local.lambda_functions_with_custom_permissions : name => config
    if length(config.permissions.statements) > 0
  }
  
  # Service role type mapping
  service_role_types = {
    for name, config in local.services_unified_enabled : name => (
      config.permissions != null ? "custom" : "shared"
    )
  }
  
  # Lambda role type mapping
  lambda_role_types = {
    for name, config in local.lambda_functions_enabled : name => (
      try(config.permissions, null) != var.lambda.permissions ? "custom" : "shared"
    )
  }
  
  # Consolidated policy flags
  iam_policies_needed = {
    service_s3_policy = length(local.services_needing_s3) > 0
    service_ses_policy = length(local.services_needing_ses) > 0
    service_aurora_iam_policy = length(local.services_needing_aurora_iam) > 0
    lambda_s3_policy = length(local.lambda_functions_needing_s3) > 0 
    lambda_ses_policy = length(local.lambda_functions_needing_ses) > 0
    lambda_fargate_policy = length(local.lambda_functions_needing_fargate) > 0
    lambda_aurora_iam_policy = length(local.lambda_functions_needing_aurora_iam) > 0
  }

  # Lambda unified processing
  lambda_functions_unified = {
    for name, config in var.lambda.functions : name => {
      enabled     = config.enabled
      source_dir  = config.source_dir
      handler     = config.handler != null ? config.handler : var.lambda.handler
      runtime     = config.runtime != null ? config.runtime : var.lambda.runtime
      timeout     = config.timeout != null ? config.timeout : var.lambda.timeout
      memory_size = config.memory_size != null ? config.memory_size : var.lambda.memory_size

      reserved_concurrency = config.reserved_concurrency != null ? config.reserved_concurrency : var.lambda.reserved_concurrency
      provisioned_concurrency = config.provisioned_concurrency != null ? config.provisioned_concurrency : var.lambda.provisioned_concurrency

      kms = config.kms != null ? config.kms : var.lambda.kms

      version_management = config.version_management != null ? config.version_management : var.lambda.version_management

      layers = concat(var.lambda.layers, config.layers != null ? config.layers : [])

      triggers = config.triggers

      monitoring = config.monitoring

      network_access = concat(var.lambda.network_access, config.network_access != null ? config.network_access : [])

      fargate = config.fargate != null ? config.fargate : var.lambda.fargate

      efs_config = merge(
        var.lambda.efs,
        config.efs != null ? config.efs : {}
      )

      # Permissions (merge if function has custom permissions, otherwise use global)
      permissions = config.permissions != null ? {
        s3         = config.permissions.s3 != null ? config.permissions.s3 : var.lambda.permissions.s3
        fargate    = config.permissions.fargate != null ? config.permissions.fargate : var.lambda.permissions.fargate
        ses        = config.permissions.ses != null ? config.permissions.ses : var.lambda.permissions.ses
        statements = concat(var.lambda.permissions.statements, config.permissions.statements != null ? config.permissions.statements : [])
      } : var.lambda.permissions

      database_config = config.environment != null && config.environment.database != null ? config.environment.database : var.lambda.environment.database
      database_env_var_name = (
        (config.environment != null && config.environment.database != null ? config.environment.database : var.lambda.environment.database) == null ? null :
        (config.environment != null && config.environment.database != null ? config.environment.database : var.lambda.environment.database) == true ? "DATABASE_URL" :
        can(tostring(config.environment != null && config.environment.database != null ? config.environment.database : var.lambda.environment.database)) ? tostring(config.environment != null && config.environment.database != null ? config.environment.database : var.lambda.environment.database) :
        try((config.environment != null && config.environment.database != null ? config.environment.database : var.lambda.environment.database).name, "DATABASE_URL")
      )

      enhanced_secrets = merge(
        var.lambda.secrets,
        config.secrets != null ? config.secrets : {},
        (config.environment != null && config.environment.database != null ? config.environment.database : var.lambda.environment.database) != null && local.rds_enabled ? {
          (
            (config.environment != null && config.environment.database != null ? config.environment.database : var.lambda.environment.database) == null ? null :
            (config.environment != null && config.environment.database != null ? config.environment.database : var.lambda.environment.database) == true ? "DATABASE_URL" :
            can(tostring(config.environment != null && config.environment.database != null ? config.environment.database : var.lambda.environment.database)) ? tostring(config.environment != null && config.environment.database != null ? config.environment.database : var.lambda.environment.database) :
            try((config.environment != null && config.environment.database != null ? config.environment.database : var.lambda.environment.database).name, "DATABASE_URL")
          ) = (
            (config.environment != null && config.environment.database != null ? config.environment.database : var.lambda.environment.database) == true ? "DATABASE_URL_FROM_DEFAULT_SECRET" :
            can(tostring(config.environment != null && config.environment.database != null ? config.environment.database : var.lambda.environment.database)) ? "DATABASE_URL_FROM_DEFAULT_SECRET" :
            try((config.environment != null && config.environment.database != null ? config.environment.database : var.lambda.environment.database).secret, "DATABASE_URL_FROM_DEFAULT_SECRET")
          )
        } : {}
      )

      enhanced_environment_variables = merge(
        var.lambda.environment.variables,
        config.environment != null ? config.environment.variables : {},
        (config.environment != null && config.environment.database != null ? config.environment.database : var.lambda.environment.database) != null && local.rds_enabled ? {
          (
            (config.environment != null && config.environment.database != null ? config.environment.database : var.lambda.environment.database) == null ? null :
            (config.environment != null && config.environment.database != null ? config.environment.database : var.lambda.environment.database) == true ? "DATABASE_URL" :
            can(tostring(config.environment != null && config.environment.database != null ? config.environment.database : var.lambda.environment.database)) ? tostring(config.environment != null && config.environment.database != null ? config.environment.database : var.lambda.environment.database) :
            try((config.environment != null && config.environment.database != null ? config.environment.database : var.lambda.environment.database).name, "DATABASE_URL")
          ) = "DATABASE_URL_FROM_SECRET" # Placeholder, actual value set at runtime
        } : {}
      )

      environment = {
        database = config.environment != null && config.environment.database != null ? config.environment.database : var.lambda.environment.database
        s3       = config.environment != null && config.environment.s3 != null ? config.environment.s3 : var.lambda.environment.s3
        variables = merge(
          var.lambda.environment.variables,
          config.environment != null ? config.environment.variables : {}
        )
      }
    }
  }

  # Enabled lambda functions
  lambda_functions_enabled = {
    for name, config in local.lambda_functions_unified : name => config
    if config.enabled
  }

  # Lambda S3 triggers processing
  lambda_s3_triggers = {
    for name, config in local.lambda_functions_enabled : name => {
      events        = config.triggers.s3.events
      filter_prefix = config.triggers.s3.filter_prefix
      filter_suffix = config.triggers.s3.filter_suffix
    }
    if config.triggers.s3 != null && config.triggers.s3.enabled
  }

  # Lambda functions that need SQS access
  lambda_functions_needing_sqs = {
    for name, config in local.lambda_functions_enabled : name => config
    if config.triggers.sqs != null && config.triggers.sqs.enabled
  }

  # Functions that need version cleanup
  lambda_functions_with_cleanup = {
    for name, config in local.lambda_functions_enabled : name => config
    if config.version_management.publish_versions && config.version_management.max_versions_to_keep > 0
  }

  # Created layers that need pruning
  lambda_created_layers = flatten([
    for name, config in local.lambda_functions_enabled : [
      for idx, layer in config.layers : {
        function_name = name
        layer_name    = "${var.name}-${layer.name}"
        max_versions  = layer.max_versions
      }
      if(layer.zip_file != null || layer.dir != null) && layer.name != null
    ]
  ])

  # Lambda database check
  lambda_needs_database = anytrue([
    for name, config in local.lambda_functions_enabled :
    config.environment.database != null && config.environment.database != false
  ])

  # Lambda VPC check
  lambda_needs_vpc = anytrue([
    for name, config in local.lambda_functions_enabled : (
      (config.environment.database != null && config.environment.database != false) ||
      length(config.enhanced_secrets) > 0 ||
      length(config.network_access) > 0 ||
      length(config.efs_config) > 0
    )
  ])

  # Lambda functions that need ALB integration
  lambda_needing_alb = {
    for name, config in local.lambda_functions_enabled : name => config
    if config.triggers.http != null && config.triggers.http.enabled && config.triggers.http.subdomain == null && config.triggers.http.path_pattern != null
  }

  # Lambda functions with VPC access
  lambda_functions_with_vpc_access = {
    for name, config in local.lambda_functions_enabled : name => config
    if(config.environment.database != null && config.environment.database != false) ||
    length(config.enhanced_secrets) > 0 ||
    length(config.network_access) > 0 ||
    length(config.efs_config) > 0
  }

  # Service unified processing
  services_unified = {
    for name, config in var.services : name => merge(config, {
      enhanced_secrets = merge(
        {
          for env_var_name, secret_ref in try(config.secrets, {}) :
          env_var_name => length(split(":", secret_ref)) > 1 ?
            try("${data.aws_secretsmanager_secret.enhanced_secrets[split(":", secret_ref)[0]].arn}:${join(":", slice(split(":", secret_ref), 1, length(split(":", secret_ref))))}::",
                "${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${split(":", secret_ref)[0]}:${join(":", slice(split(":", secret_ref), 1, length(split(":", secret_ref))))}::") :
            try(data.aws_secretsmanager_secret.enhanced_secrets[secret_ref].arn,
                "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${secret_ref}")
        },
        local.rds_enabled && config.environment.database != null ? {
          (
            config.environment.database == null ? null :
            config.environment.database == true ? "DATABASE_URL" :
            can(tostring(config.environment.database)) ? tostring(config.environment.database) :
            try(config.environment.database.name, "DATABASE_URL")
          ) = (
            try(config.environment.database.secret, null) != null ? (
              startswith(config.environment.database.secret, "arn:aws:secretsmanager:") ? 
                config.environment.database.secret :
                length(split(":", config.environment.database.secret)) > 1 ?
                  try("${data.aws_secretsmanager_secret.enhanced_secrets[split(":", config.environment.database.secret)[0]].arn}:${join(":", slice(split(":", config.environment.database.secret), 1, length(split(":", config.environment.database.secret))))}::",
                      "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${split(":", config.environment.database.secret)[0]}:${join(":", slice(split(":", config.environment.database.secret), 1, length(split(":", config.environment.database.secret))))}::") :
                  try(data.aws_secretsmanager_secret.enhanced_secrets[config.environment.database.secret].arn,
                      "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${config.environment.database.secret}")
            ) : "${aws_secretsmanager_secret.database_url[0].arn}:DATABASE_URL_ACTIVE::"
          )
        } : {}
      )

      unified_mounts = {
        volumes = merge(
          config.efs != null ? {
            for mount_name, mount_config in config.efs :
            mount_name => {
              type = "efs"
              efs_config = mount_config
            }
          } : {},
          config.volumes != null ? {
            for volume_name, volume_config in config.volumes :
            volume_name => {
              type = "custom"
              host_path = (
                volume_config == null ? null :
                can(tostring(volume_config)) && volume_config != null ? tostring(volume_config) :
                can(volume_config.path) ? volume_config.path : null
              )
            }  
          } : {}
        )
        
        mount_points = merge(
          config.efs != null ? {
            for mount_name, mount_config in config.efs :
            mount_name => {
              container_path = mount_config.path
              readonly = mount_config.readonly != null ? mount_config.readonly : false
              source_volume = mount_name
            }
          } : {},
          config.mount != null ? {
            for volume_name, mount_config in config.mount :
            volume_name => {
              container_path = (
                mount_config == null ? "/mnt/${volume_name}" :
                can(tostring(mount_config)) && mount_config != null ? tostring(mount_config) :
                can(mount_config.path) ? mount_config.path : "/mnt/${volume_name}"
              )
              readonly = (
                mount_config != null && can(mount_config.readonly) && mount_config.readonly != null ? 
                mount_config.readonly : false
              )
              source_volume = volume_name
            }
          } : {}
        )
      }

      database_config = config.environment.database
      database_env_var_name = (
        config.environment.database == null ? null :
        config.environment.database == true ? "DATABASE_URL" :
        can(tostring(config.environment.database)) ? tostring(config.environment.database) :
        try(config.environment.database.name, "DATABASE_URL")
      )
    })
  }

  # Enabled services
  services_unified_enabled = {
    for name, config in local.services_unified : name => config
    if config.enabled
  }

  # HTTP services
  http_services = {
    for name, config in local.services_unified_enabled : name => config
    if config.http != null
  }

  # Background services
  background_services = {
    for name, config in local.services_unified_enabled : name => config
    if config.http == null
  }

  # Lambda functions with HTTP triggers enabled
  lambda_with_http = {
    for name, config in local.lambda_functions_enabled : name => config
    if config.triggers.http != null && config.triggers.http.enabled
  }

  # Lambda functions with CloudFront routing
  lambda_with_cloudfront = {
    for name, config in local.lambda_with_http : name => config
    if config.triggers.http.path_pattern != null && !config.triggers.http.alb
  }

  # Lambda functions with subdomain routing
  lambda_with_subdomain = {
    for name, config in local.lambda_with_http : name => config
    if config.triggers.http.subdomain != null
  }

  # Services with subdomain routing
  services_with_subdomain = {
    for name, config in local.http_services : name => config
    if config.http.subdomain != null
  }

  # Services with external DNS requirements
  services_with_dns = {
    for name, config in local.services_with_subdomain : name => config
    if var.dns.domain != null && local.subdomain_routing_allowed
  }

  # Lambda functions that explicitly request ALB
  lambda_requesting_alb = {
    for name, config in local.lambda_with_http : name => config
    if config.triggers.http.alb == true
  }

  # Lambda functions with subdomain routing
  lambda_with_subdomain_routing = {
    for name, config in local.lambda_with_http : name => config
    if config.triggers.http.subdomain != null
  }

  # Services that need external ALB routing
  services_needing_alb = {
    for name, config in local.http_services : name => config
    if config.http.subdomain != null || config.http.path_pattern != null
  }

  # Determine if ALB should be created
  alb_enabled = var.dns.alb || length(local.services_needing_alb) > 0 || length(local.lambda_requesting_alb) > 0 || length(local.lambda_with_subdomain_routing) > 0

  # ALB configuration flags
  alb_config = {
    enabled = local.alb_enabled
    needs_www_redirect = local.alb_enabled && local.subdomain_routing_allowed && local.www_redirect_enabled
  }

  # ALB listener rule priorities
  alb_service_rule_priorities = {
    for idx, name in keys(local.services_needing_alb) :
    name => 100 + idx
  }

  alb_lambda_rule_priorities = {
    for idx, name in keys(local.lambda_needing_alb) :
    name => 1000 + idx
  }

  # EFS configuration flags
  efs_config = {
    enabled = var.efs.enabled
    needs_bastion_access = var.efs.enabled && anytrue([
      for config in values(local.bastion_configs_enabled) : config.efs
    ])
    needs_lambda_access = local.efs_used_by_lambda
  }

  # Services that use EFS
  services_with_efs = {
    for name, config in local.services_unified_enabled : name => config
    if config.efs != null && length(config.efs) > 0
  }

  # Lambda functions that use EFS
  lambda_functions_with_efs = {
    for name, config in local.lambda_functions_enabled : name => config
    if length(config.efs_config) > 0
  }

  # EFS mount points configuration
  efs_mount_points = var.efs.enabled ? var.efs.mounts : {}

  # EFS usage tracking
  efs_used_by_services = length(local.services_with_efs) > 0
  efs_used_by_lambda   = length(local.lambda_functions_with_efs) > 0
  efs_in_use           = local.efs_used_by_services || local.efs_used_by_lambda

  # Lambda EFS VPC check
  lambda_needs_efs_vpc = length(local.lambda_functions_with_efs) > 0

  # Bastion EFS mounts - per bastion instance
  bastion_efs_mounts = var.efs.enabled ? {
    for bastion_name, bastion_config in local.bastion_configs_enabled :
    bastion_name => bastion_config.efs ? {
      for mount_name, mount_config in var.efs.mounts :
      mount_name => {
        path     = "/mount/${mount_name}"
        readonly = false
      }
    } : {}
  } : {}

  # Monitoring configuration flags
  monitoring_config = {
    enabled = var.monitoring.enabled
    dashboard_enabled = var.monitoring.enabled && var.monitoring.dashboard.enabled
    log_monitoring_enabled = var.monitoring.enabled && var.monitoring.log_monitoring.enabled
    aurora_monitoring_enabled = var.monitoring.enabled && local.rds_enabled && local.is_aurora
    alb_monitoring_enabled = var.monitoring.enabled && local.alb_config.enabled
    cloudfront_monitoring_enabled = var.monitoring.enabled && local.s3_enabled && var.s3.public != null
    services_monitoring_enabled = length(local.services_unified_enabled) > 0
    lambda_monitoring_enabled = length(local.lambda_functions_enabled) > 0
  }

  # Services that have monitoring enabled
  services_with_monitoring = {
    for service_name, service_config in var.services : service_name => service_config
    if var.monitoring.enabled && service_config.monitoring
  }

  # Services with log monitoring
  services_with_log_monitoring = {
    for service_name, service_config in var.services : service_name => service_config
    if var.monitoring.enabled && var.monitoring.log_monitoring.enabled && service_config.monitoring
  }

  # Services with ALB monitoring
  services_with_alb_monitoring = local.alb_config.enabled ? {
    for service_name, service_config in local.services_needing_alb : service_name => service_config
    if var.monitoring.enabled && service_config.monitoring
  } : {}

  # Check if any service has local DNS enabled
  has_local_services = length(local.services_with_local_dns) > 0
}