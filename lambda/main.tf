# Data source for current AWS account
data "aws_caller_identity" "current" {}

# Use shared environment module
# Smart environment configuration for Lambda with global fallbacks
locals {
  # Apply global defaults with function-level overrides
  effective_runtime     = var.function_config.runtime != null ? var.function_config.runtime : var.global_config.runtime
  effective_handler     = var.function_config.handler != null ? var.function_config.handler : var.global_config.handler
  effective_timeout     = var.function_config.timeout != null ? var.function_config.timeout : var.global_config.timeout
  effective_memory_size = var.function_config.memory_size != null ? var.function_config.memory_size : var.global_config.memory_size
  effective_provisioned_concurrency = var.function_config.provisioned_concurrency != null ? var.function_config.provisioned_concurrency : var.global_config.provisioned_concurrency
  effective_reserved_concurrency    = var.function_config.reserved_concurrency != null ? var.function_config.reserved_concurrency : var.global_config.reserved_concurrency
  effective_dead_letter_queue       = var.function_config.dead_letter_queue != null ? var.function_config.dead_letter_queue : var.global_config.dead_letter_queue
  effective_version_management = var.function_config.version_management != null ? var.function_config.version_management : var.global_config.version_management
  effective_kms               = var.function_config.kms != null ? var.function_config.kms : var.global_config.kms
  effective_log_retention_days = var.function_config.log_retention_days != null ? var.function_config.log_retention_days : var.global_config.log_retention_days
  effective_monitoring         = var.function_config.monitoring != null ? var.function_config.monitoring : var.global_config.monitoring

  # Merge logic for environment, secrets, and layers (global + function-specific)
  # Environment: merge global environment with function environment
  merged_environment = {
    # Merge global and function environment variables (function takes precedence for conflicts)
    node      = var.function_config.environment.node != null ? var.function_config.environment.node : var.global_config.environment.node
    s3        = var.function_config.environment.s3 != null ? var.function_config.environment.s3 : var.global_config.environment.s3
    database  = var.function_config.environment.database != null ? var.function_config.environment.database : var.global_config.environment.database
    variables = merge(var.global_config.environment.variables, var.function_config.environment.variables)
  }
  
  # Secrets: merge global secrets with function secrets (function takes precedence for conflicts)
  merged_secrets = merge(var.global_config.secrets, var.function_config.secrets)
  
  # Layers: concatenate global layers with function layers (global first, then function)
  merged_layers = concat(var.global_config.layers, var.function_config.layers)
  
  # Network access: concatenate global network access with function network access (global first, then function)
  merged_network_access = concat(var.global_config.network_access, var.function_config.network_access)
  
  # EFS: merge global EFS with function EFS (function takes precedence for conflicts)
  merged_efs = merge(var.global_config.efs, var.function_config.efs)

  # Original locals
  # Auto-detect Node.js runtime and set node = true by default
  is_nodejs_runtime = startswith(local.effective_runtime, "nodejs")
  
  # Smart environment config: auto-enable NODE_ENV for Node.js runtimes
  smart_environment_config = {
    # Remove region for Lambda (AWS provides AWS_REGION automatically)
    region = null
    # Auto-enable node for Node.js runtimes if not explicitly set
    node = local.merged_environment.node != null ? local.merged_environment.node : (local.is_nodejs_runtime ? true : false)
    # Remove database - now handled via secrets
    s3 = local.merged_environment.s3
    variables = local.merged_environment.variables
  }
  
  # Convert environment variables list to map format for Lambda
  all_environment_variables = {
    for env_var in module.lambda_environment.environment_variables : env_var.name => env_var.value
  }
  
  # Node.js dependency layer management
  has_package_json  = fileexists("${var.function_config.source_dir}/package.json")
  has_package_lock  = fileexists("${var.function_config.source_dir}/package-lock.json")
  
  # Should we create a Node.js dependency layer?
  should_create_node_layer = local.is_nodejs_runtime && local.has_package_json && local.has_package_lock
  
  # Docker runtime mapping for Lambda
  docker_runtime_map = {
    "nodejs18.x" = "18"
    "nodejs20.x" = "20" 
    "nodejs22.x" = "22"
  }
  
  docker_node_version = local.should_create_node_layer ? lookup(local.docker_runtime_map, local.effective_runtime, "20") : "20"
  
  # Generate layer name for Node.js dependencies
  node_layer_name = local.should_create_node_layer ? "${var.config.name}-${var.function_name}-node-deps" : null
  
  # Combine configured layers with auto-generated Node.js layer
  configured_layer_arns = length(local.merged_layers) > 0 ? [
    for layer in local.merged_layers : (
      layer.arn != null ? layer.arn : 
      layer.zip_file != null ? aws_lambda_layer_version.created_layers[layer.name].arn :
      layer.dir != null ? aws_lambda_layer_version.dir_layers[layer.name].arn :
      null
    )
  ] : []
  
  # All layer ARNs (configured + auto-generated Node.js layer)
  all_layer_arns = concat(
    local.configured_layer_arns,
    local.should_create_node_layer ? [aws_lambda_layer_version.nodejs_deps[0].arn] : []
  )
}

module "lambda_environment" {
  source = "../modules/environment"

  service_name       = var.function_name
  service_type       = "lambda"
  environment_config = local.smart_environment_config
  secrets_config     = {} # Secrets are now handled at the global level

  global_config = {
    name           = var.config.name
    aws_region     = var.config.aws_region
    environment    = "production" # Lambda doesn't have environment context like services
    s3_enabled     = var.config.s3_bucket_name != null
    s3_bucket_name = var.config.s3_bucket_name
  }
}


# Create ZIP archive for Lambda function
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = var.function_config.source_dir
  output_path = "${var.config.tmp_directory}/terraform-${var.config.name}-${var.function_name}.zip"

  # Exclude node_modules if we're creating a Node.js dependency layer
  excludes = local.should_create_node_layer ? [
    "node_modules",
    "package-lock.json",
    ".npm",
    ".npmrc"
  ] : []
}

# Cleanup Lambda ZIP file immediately after deployment
resource "null_resource" "lambda_zip_cleanup" {
  # Trigger whenever the Lambda function is updated
  triggers = {
    lambda_function_id = aws_lambda_function.main.id
    source_code_hash   = data.archive_file.lambda_zip.output_base64sha256
  }

  # Delete ZIP file immediately after Lambda deployment (no need to keep it)
  provisioner "local-exec" {
    command = <<-EOT
      echo "Cleaning up Lambda ZIP file after deployment..."
      rm -f "${data.archive_file.lambda_zip.output_path}" || true
      echo "Lambda ZIP file deleted: ${data.archive_file.lambda_zip.output_path}"
    EOT
  }

  depends_on = [aws_lambda_function.main]
}


# Docker build for Node.js dependencies (triggered by package-lock.json hash)
resource "null_resource" "nodejs_deps_build" {
  count = local.should_create_node_layer ? 1 : 0

  # Trigger rebuild when package-lock.json changes
  triggers = {
    package_lock_hash = filesha256("${var.function_config.source_dir}/package-lock.json")
    package_json_hash = filesha256("${var.function_config.source_dir}/package.json")
    runtime           = var.function_config.runtime
    function_name     = var.function_name
  }

  # Create build directory and run Docker build
  provisioner "local-exec" {
    command = <<-EOT
      set -e

      # Clean and create build directory
      rm -rf "${var.config.tmp_directory}/terraform-${var.config.name}-nodejs-layers/${var.function_name}" 2>/dev/null || true
      mkdir -p "${var.config.tmp_directory}/terraform-${var.config.name}-nodejs-layers/${var.function_name}"
      BUILD_DIR="${var.config.tmp_directory}/terraform-${var.config.name}-nodejs-layers/${var.function_name}"

      # Copy package files to build directory
      cp "${var.function_config.source_dir}/package.json" "$BUILD_DIR/"
      cp "${var.function_config.source_dir}/package-lock.json" "$BUILD_DIR/"

      # Run Docker build with Lambda runtime environment
      echo "Building Node.js dependencies for ${local.effective_runtime}..."
      docker run --rm \
        -v "$BUILD_DIR":/var/task \
        -w /var/task \
        --platform linux/amd64 \
        --entrypoint=/bin/bash \
        public.ecr.aws/lambda/nodejs:${local.docker_node_version} \
        -c "npm ci --only=production --no-audit --no-fund && mkdir -p nodejs && cp -r node_modules nodejs/"

      # Create zip file with proper Lambda layer structure
      cd "$BUILD_DIR"
      zip -r "${var.function_name}-deps.zip" nodejs/

      echo "Node.js dependencies built successfully for ${var.function_name}"
    EOT
  }

}

# Lambda layer for Node.js dependencies
resource "aws_lambda_layer_version" "nodejs_deps" {
  count = local.should_create_node_layer ? 1 : 0

  layer_name               = local.node_layer_name
  filename                 = "${var.config.tmp_directory}/terraform-${var.config.name}-nodejs-layers/${var.function_name}/${var.function_name}-deps.zip"
  compatible_runtimes      = [local.effective_runtime]
  compatible_architectures = ["x86_64"]
  description              = "Node.js dependencies for ${var.function_name}"

  # Ensure the build completes before creating the layer
  depends_on = [null_resource.nodejs_deps_build]
}

# Cleanup Node.js dependency layer ZIP immediately after deployment
resource "null_resource" "nodejs_layer_zip_cleanup" {
  count = local.should_create_node_layer ? 1 : 0

  # Trigger whenever the layer is updated
  triggers = {
    layer_version_arn = aws_lambda_layer_version.nodejs_deps[0].arn
    build_hash        = null_resource.nodejs_deps_build[0].triggers.package_lock_hash
  }

  # Delete ZIP file and build directory immediately after layer deployment
  provisioner "local-exec" {
    command = <<-EOT
      echo "Cleaning up Node.js dependency layer files after deployment..."
      rm -rf "${var.config.tmp_directory}/terraform-${var.config.name}-nodejs-layers/${var.function_name}" || true
      echo "Node.js dependency layer files deleted for ${var.function_name}"
    EOT
  }

  depends_on = [aws_lambda_layer_version.nodejs_deps]
}

# Lambda layer for manually configured layers (from zip files)
resource "aws_lambda_layer_version" "created_layers" {
  for_each = {
    for layer in local.merged_layers : layer.name => layer
    if layer.zip_file != null && layer.name != null
  }

  layer_name               = "${var.config.name}-${each.value.name}"
  filename                 = each.value.zip_file
  compatible_runtimes      = each.value.compatible_runtimes != null ? each.value.compatible_runtimes : var.config.default_compatible_runtimes
  compatible_architectures = ["x86_64"]
  description              = each.value.description
  license_info             = each.value.license_info
}

# ZIP archive creation for directory-based layers
data "archive_file" "dir_layer_zip" {
  for_each = {
    for layer in local.merged_layers : layer.name => layer
    if layer.dir != null && layer.name != null
  }

  type        = "zip"
  source_dir  = each.value.dir
  output_path = "${var.config.tmp_directory}/terraform-${var.config.name}-${each.value.name}-layer.zip"
}

# Lambda layer for directory-based layers
resource "aws_lambda_layer_version" "dir_layers" {
  for_each = {
    for layer in local.merged_layers : layer.name => layer
    if layer.dir != null && layer.name != null
  }

  layer_name               = "${var.config.name}-${each.value.name}"
  filename                 = data.archive_file.dir_layer_zip[each.key].output_path
  source_code_hash         = data.archive_file.dir_layer_zip[each.key].output_base64sha256
  compatible_runtimes      = each.value.compatible_runtimes != null ? each.value.compatible_runtimes : var.config.default_compatible_runtimes
  compatible_architectures = ["x86_64"]
  description              = each.value.description
  license_info             = each.value.license_info
}

# Cleanup directory-based layer ZIP files after deployment
resource "null_resource" "dir_layer_zip_cleanup" {
  for_each = {
    for layer in local.merged_layers : layer.name => layer
    if layer.dir != null && layer.name != null
  }

  # Trigger whenever the layer is updated
  triggers = {
    layer_version_arn = aws_lambda_layer_version.dir_layers[each.key].arn
    source_code_hash  = data.archive_file.dir_layer_zip[each.key].output_base64sha256
  }

  # Delete ZIP file immediately after layer deployment
  provisioner "local-exec" {
    command = <<-EOT
      echo "Cleaning up directory layer ZIP file after deployment..."
      rm -f "${data.archive_file.dir_layer_zip[each.key].output_path}" || true
      echo "Directory layer ZIP file deleted: ${data.archive_file.dir_layer_zip[each.key].output_path}"
    EOT
  }

  depends_on = [aws_lambda_layer_version.dir_layers]
}

# IAM role is now handled in the main iam.tf file
# This module uses the role ARN passed from the main configuration

# Lambda function
resource "aws_lambda_function" "main" {
  function_name = "${var.config.name}-${var.function_name}"
  role          = var.lambda_role_arn
  handler       = local.effective_handler
  runtime       = local.effective_runtime
  timeout       = local.effective_timeout
  memory_size   = local.effective_memory_size

  # Lambda layers (use combined ARNs from created and existing layers)
  layers = local.all_layer_arns

  # Reserved concurrency (not configured in this module)
  # reserved_concurrent_executions = -1

  # Don't publish versions by default
  publish = false

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  # Dead letter configuration
  dynamic "dead_letter_config" {
    for_each = local.effective_dead_letter_queue != null ? [1] : []
    content {
      target_arn = local.effective_dead_letter_queue
    }
  }

  # Environment variables from shared module
  dynamic "environment" {
    for_each = length(local.all_environment_variables) > 0 ? [1] : []
    content {
      variables = local.all_environment_variables
    }
  }
  
  # KMS encryption for environment variables
  kms_key_arn = (local.effective_kms != null && local.effective_kms != false && local.effective_kms != true) ? local.effective_kms : null

  # VPC configuration - attach security group for Lambda functions that need secrets access, network access, or EFS
  dynamic "vpc_config" {
    for_each = length(local.merged_secrets) > 0 || length(local.merged_network_access) > 0 || length(local.merged_efs) > 0 ? [1] : []
    content {
      subnet_ids = var.config.vpc.subnet_ids
      # Attach shared Lambda security group if available (automatically managed)
      security_group_ids = compact([var.config.lambda_shared_security_group_id])
    }
  }
  
  # EFS file system configuration
  dynamic "file_system_config" {
    for_each = var.config.efs_enabled ? local.merged_efs : {}
    content {
      arn              = var.config.efs_access_points[file_system_config.key]
      local_mount_path = file_system_config.value.path
    }
  }

  tags = merge(var.config.common_tags, {
    Name = "${var.config.name}-${var.function_name}"
  })
}

# Provisioned Concurrency Configuration 
resource "aws_lambda_provisioned_concurrency_config" "main" {
  count = local.effective_provisioned_concurrency != null && local.effective_provisioned_concurrency > 0 ? 1 : 0
  
  function_name                     = aws_lambda_function.main.function_name
  provisioned_concurrent_executions = local.effective_provisioned_concurrency
  qualifier                         = aws_lambda_function.main.version

  # Wait for the function to be ready
  depends_on = [aws_lambda_function.main]
}


# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${aws_lambda_function.main.function_name}"
  retention_in_days = local.effective_log_retention_days
  
  # Encryption configuration
  kms_key_id = (local.effective_kms != null && local.effective_kms != false && local.effective_kms != true) ? local.effective_kms : null

  tags = var.config.common_tags
}
