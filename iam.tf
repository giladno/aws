# Shared IAM Role for ECS Services (default role with S3 access)
resource "aws_iam_role" "ecs_shared_task_role" {
  count = length(local.services_unified_enabled) > 0 ? 1 : 0

  name = "${var.name}-ecs-shared-task-role"

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

# Shared IAM Policy for S3 Access (used by default)
resource "aws_iam_role_policy" "ecs_shared_s3_access" {
  count = length(local.services_unified_enabled) > 0 && local.s3_enabled ? 1 : 0

  name = "${var.name}-ecs-shared-s3-policy"
  role = aws_iam_role.ecs_shared_task_role[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          aws_s3_bucket.main[0].arn,
          "${aws_s3_bucket.main[0].arn}/*"
        ]
      }
    ]
  })
}

# Custom IAM Roles for Services with specific permissions
resource "aws_iam_role" "ecs_custom_task_role" {
  for_each = local.services_with_custom_roles

  name = "${var.name}-${each.key}-task-role"

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

  tags = merge(local.common_tags, {
    Service = each.key
  })
}

# Consolidated IAM Policy for Services with S3 access
resource "aws_iam_policy" "ecs_s3_access" {
  count = local.iam_policies_needed.service_s3_policy ? 1 : 0

  name        = "${var.name}-ecs-s3-access-policy"
  description = "S3 access policy for ECS services"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          aws_s3_bucket.main[0].arn,
          "${aws_s3_bucket.main[0].arn}/*"
        ]
      }
    ]
  })

  tags = local.common_tags
}

# Attach consolidated S3 policy to services that need it
resource "aws_iam_role_policy_attachment" "ecs_custom_s3_access" {
  for_each = local.services_needing_s3

  role       = aws_iam_role.ecs_custom_task_role[each.key].name
  policy_arn = aws_iam_policy.ecs_s3_access[0].arn
}

# Consolidated IAM Policy for Services with SES permissions
resource "aws_iam_policy" "ecs_ses_access" {
  count = local.iam_policies_needed.service_ses_policy ? 1 : 0

  name        = "${var.name}-ecs-ses-access-policy"
  description = "SES access policy for ECS services"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ses:SendEmail",
          "ses:SendRawEmail",
          "ses:SendBulkTemplatedEmail",
          "ses:SendTemplatedEmail",
          "ses:GetSendQuota",
          "ses:GetSendStatistics",
          "ses:ListIdentities",
          "ses:GetIdentityVerificationAttributes",
          "ses:GetIdentityDkimAttributes"
        ]
        Resource = [
          aws_ses_domain_identity.main[0].arn,
          "${aws_ses_domain_identity.main[0].arn}/*"
        ]
      }
    ]
  })

  tags = local.common_tags
}

# Attach consolidated SES policy to services that need it
resource "aws_iam_role_policy_attachment" "ecs_custom_ses_access" {
  for_each = local.services_needing_ses

  role       = aws_iam_role.ecs_custom_task_role[each.key].name
  policy_arn = aws_iam_policy.ecs_ses_access[0].arn
}

# Consolidated IAM Policies for Services with custom statements
resource "aws_iam_policy" "ecs_custom_statements" {
  for_each = local.services_with_custom_statements

  name        = "${var.name}-${each.key}-custom-statements-policy"
  description = "Custom IAM statements for ${each.key} service"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      for stmt in each.value.permissions.statements : {
        Effect   = stmt.effect
        Action   = stmt.actions
        Resource = stmt.resources
        Condition = stmt.condition != null ? {
          "${stmt.condition.test}" = {
            "${stmt.condition.variable}" = stmt.condition.values
          }
        } : null
      }
    ]
  })

  tags = merge(local.common_tags, {
    Service = each.key
  })
}

# Attach custom statement policies to services that need them
resource "aws_iam_role_policy_attachment" "ecs_custom_statements" {
  for_each = local.services_with_custom_statements

  role       = aws_iam_role.ecs_custom_task_role[each.key].name
  policy_arn = aws_iam_policy.ecs_custom_statements[each.key].arn
}

# Consolidated IAM Policy for Services with Aurora IAM database authentication
resource "aws_iam_policy" "ecs_aurora_iam_auth" {
  count = local.iam_policies_needed.service_aurora_iam_policy ? 1 : 0

  name        = "${var.name}-ecs-aurora-iam-auth-policy"
  description = "Aurora IAM database authentication policy for ECS services"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "rds-db:connect"
        ]
        Resource = [
          "arn:aws:rds-db:${var.aws_region}:${data.aws_caller_identity.current.account_id}:dbuser:${aws_rds_cluster.main[0].cluster_identifier}/${var.rds.username}"
        ]
      }
    ]
  })

  tags = local.common_tags
}

# Attach Aurora IAM auth policy to services that need it
resource "aws_iam_role_policy_attachment" "ecs_aurora_iam_auth" {
  for_each = local.services_needing_aurora_iam

  role       = each.value.permissions != null ? aws_iam_role.ecs_custom_task_role[each.key].name : aws_iam_role.ecs_shared_task_role[0].name
  policy_arn = aws_iam_policy.ecs_aurora_iam_auth[0].arn
}

# Shared IAM Role for Lambda Functions (default role with S3 access)
resource "aws_iam_role" "lambda_shared_execution_role" {
  count = length(var.lambda.functions) > 0 ? 1 : 0

  name = "${var.name}-lambda-shared-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = local.common_tags
}

# Basic Lambda execution policy for shared role
resource "aws_iam_role_policy_attachment" "lambda_shared_basic" {
  count = length(var.lambda.functions) > 0 ? 1 : 0

  role       = aws_iam_role.lambda_shared_execution_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# VPC execution policy for shared Lambda role (if any Lambda uses VPC)
resource "aws_iam_role_policy_attachment" "lambda_shared_vpc" {
  count = length(var.lambda.functions) > 0 && local.lambda_needs_vpc ? 1 : 0

  role       = aws_iam_role.lambda_shared_execution_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# Shared IAM Policy for Lambda S3 Access (global permissions)
resource "aws_iam_role_policy" "lambda_shared_s3_access" {
  count = length(var.lambda.functions) > 0 && local.s3_enabled && (var.lambda.permissions.s3 || local.iam_policies_needed.lambda_s3_policy) ? 1 : 0

  name = "${var.name}-lambda-shared-s3-policy"
  role = aws_iam_role.lambda_shared_execution_role[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          aws_s3_bucket.main[0].arn,
          "${aws_s3_bucket.main[0].arn}/*"
        ]
      }
    ]
  })
}

# Shared IAM Policy for Lambda SES Access (global permissions)
resource "aws_iam_role_policy" "lambda_shared_ses_access" {
  count = length(var.lambda.functions) > 0 && local.ses_enabled && var.lambda.permissions.ses ? 1 : 0

  name = "${var.name}-lambda-shared-ses-policy"
  role = aws_iam_role.lambda_shared_execution_role[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ses:SendEmail",
          "ses:SendRawEmail",
          "ses:SendBulkTemplatedEmail",
          "ses:SendTemplatedEmail"
        ]
        Resource = "*"
      }
    ]
  })
}

# Shared IAM Policy for Lambda Fargate Access (global permissions)
resource "aws_iam_role_policy" "lambda_shared_fargate_access" {
  count = length(var.lambda.functions) > 0 && length(var.services) > 0 && var.lambda.permissions.fargate ? 1 : 0

  name = "${var.name}-lambda-shared-fargate-policy"
  role = aws_iam_role.lambda_shared_execution_role[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecs:RunTask",
          "ecs:StopTask",
          "ecs:DescribeTasks",
          "ecs:ListTasks"
        ]
        Resource = [
          "${aws_ecs_cluster.main.arn}",
          "${aws_ecs_cluster.main.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = "iam:PassRole"
        Resource = [
          for name, config in var.services : (
            config.permissions != null ?
            aws_iam_role.ecs_custom_task_role[name].arn :
            aws_iam_role.ecs_shared_task_role[0].arn
          )
        ]
      }
    ]
  })
}

# Shared IAM Policy for Lambda Custom Statements (global permissions)
resource "aws_iam_role_policy" "lambda_shared_custom_statements" {
  count = length(var.lambda.functions) > 0 && length(var.lambda.permissions.statements) > 0 ? 1 : 0

  name = "${var.name}-lambda-shared-custom-statements-policy"
  role = aws_iam_role.lambda_shared_execution_role[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      for stmt in var.lambda.permissions.statements : {
        Effect   = stmt.effect
        Action   = stmt.actions
        Resource = stmt.resources
        Condition = stmt.condition != null ? {
          "${stmt.condition.test}" = {
            "${stmt.condition.variable}" = stmt.condition.values
          }
        } : null
      }
    ]
  })
}

# Custom IAM Roles for Lambda Functions with specific permissions
resource "aws_iam_role" "lambda_custom_execution_role" {
  for_each = local.lambda_functions_with_custom_permissions

  name = "${var.name}-${each.key}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = merge(local.common_tags, {
    Function = each.key
  })
}

# Basic Lambda execution policy for custom roles
resource "aws_iam_role_policy_attachment" "lambda_custom_basic" {
  for_each = local.lambda_functions_with_custom_permissions

  role       = aws_iam_role.lambda_custom_execution_role[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# VPC execution policy for custom Lambda roles (if VPC is configured)
resource "aws_iam_role_policy_attachment" "lambda_custom_vpc" {
  for_each = local.lambda_functions_needing_vpc

  role       = aws_iam_role.lambda_custom_execution_role[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# Consolidated IAM Policy for Lambda with S3 access
resource "aws_iam_policy" "lambda_s3_access" {
  count = local.iam_policies_needed.lambda_s3_policy ? 1 : 0

  name        = "${var.name}-lambda-s3-access-policy"
  description = "S3 access policy for Lambda functions"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          aws_s3_bucket.main[0].arn,
          "${aws_s3_bucket.main[0].arn}/*"
        ]
      }
    ]
  })

  tags = local.common_tags
}

# Attach consolidated S3 policy to Lambda functions that need it (custom roles only)
resource "aws_iam_role_policy_attachment" "lambda_custom_s3_access" {
  for_each = {
    for name, config in local.lambda_functions_needing_s3 : name => config
    if contains(keys(local.lambda_functions_with_custom_permissions), name)
  }

  role       = aws_iam_role.lambda_custom_execution_role[each.key].name
  policy_arn = aws_iam_policy.lambda_s3_access[0].arn
}

# Consolidated IAM Policy for Lambda with SES permissions
resource "aws_iam_policy" "lambda_ses_access" {
  count = local.iam_policies_needed.lambda_ses_policy ? 1 : 0

  name        = "${var.name}-lambda-ses-access-policy"
  description = "SES access policy for Lambda functions"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ses:SendEmail",
          "ses:SendRawEmail",
          "ses:SendBulkTemplatedEmail",
          "ses:SendTemplatedEmail",
          "ses:GetSendQuota",
          "ses:GetSendStatistics",
          "ses:ListIdentities",
          "ses:GetIdentityVerificationAttributes",
          "ses:GetIdentityDkimAttributes"
        ]
        Resource = [
          aws_ses_domain_identity.main[0].arn,
          "${aws_ses_domain_identity.main[0].arn}/*"
        ]
      }
    ]
  })

  tags = local.common_tags
}

# Attach consolidated SES policy to Lambda functions that need it
resource "aws_iam_role_policy_attachment" "lambda_custom_ses_access" {
  for_each = local.lambda_functions_needing_ses

  role       = aws_iam_role.lambda_custom_execution_role[each.key].name
  policy_arn = aws_iam_policy.lambda_ses_access[0].arn
}

# Consolidated IAM Policy for Lambda with Fargate permissions
resource "aws_iam_policy" "lambda_fargate_access" {
  count = local.iam_policies_needed.lambda_fargate_policy ? 1 : 0

  name        = "${var.name}-lambda-fargate-access-policy"
  description = "Fargate access policy for Lambda functions"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecs:RunTask",
          "ecs:DescribeTasks",
          "ecs:DescribeTaskDefinition",
          "ecs:ListTasks",
          "ecs:StopTask"
        ]
        Resource = [
          "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:cluster/${aws_ecs_cluster.main.name}",
          "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:task-definition/${var.name}-*",
          "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:task/${aws_ecs_cluster.main.name}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "iam:PassRole"
        ]
        Resource = flatten([
          aws_iam_role.ecs_task_execution.arn,
          # Pass task roles for each service
          [for service_name in keys(var.services) : local.service_role_map[service_name]]
        ])
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "ecs-tasks.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = local.common_tags
}

# Attach consolidated Fargate policy to Lambda functions that need it
resource "aws_iam_role_policy_attachment" "lambda_custom_fargate_access" {
  for_each = local.lambda_functions_needing_fargate

  role       = aws_iam_role.lambda_custom_execution_role[each.key].name
  policy_arn = aws_iam_policy.lambda_fargate_access[0].arn
}

# Consolidated IAM Policies for Lambda with custom statements
resource "aws_iam_policy" "lambda_custom_statements" {
  for_each = local.lambda_functions_with_custom_statements

  name        = "${var.name}-${each.key}-custom-statements-policy"
  description = "Custom IAM statements for ${each.key} Lambda function"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      for stmt in each.value.permissions.statements : {
        Effect   = stmt.effect
        Action   = stmt.actions
        Resource = stmt.resources
        Condition = stmt.condition != null ? {
          "${stmt.condition.test}" = {
            "${stmt.condition.variable}" = stmt.condition.values
          }
        } : null
      }
    ]
  })

  tags = merge(local.common_tags, {
    Function = each.key
  })
}

# Attach custom statement policies to Lambda functions that need them
resource "aws_iam_role_policy_attachment" "lambda_custom_statements" {
  for_each = local.lambda_functions_with_custom_statements

  role       = aws_iam_role.lambda_custom_execution_role[each.key].name
  policy_arn = aws_iam_policy.lambda_custom_statements[each.key].arn
}

# Consolidated IAM Policy for Lambda functions with Aurora IAM database authentication
resource "aws_iam_policy" "lambda_aurora_iam_auth" {
  count = local.iam_policies_needed.lambda_aurora_iam_policy ? 1 : 0

  name        = "${var.name}-lambda-aurora-iam-auth-policy"
  description = "Aurora IAM database authentication policy for Lambda functions"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "rds-db:connect"
        ]
        Resource = [
          "arn:aws:rds-db:${var.aws_region}:${data.aws_caller_identity.current.account_id}:dbuser:${aws_rds_cluster.main[0].cluster_identifier}/${var.rds.username}"
        ]
      }
    ]
  })

  tags = local.common_tags
}

# Attach Aurora IAM auth policy to Lambda functions that need it
resource "aws_iam_role_policy_attachment" "lambda_aurora_iam_auth" {
  for_each = local.lambda_functions_needing_aurora_iam

  role       = each.value.permissions != var.lambda.permissions ? aws_iam_role.lambda_custom_execution_role[each.key].name : aws_iam_role.lambda_shared_execution_role[0].name
  policy_arn = aws_iam_policy.lambda_aurora_iam_auth[0].arn
}

# SQS Access Policy for Lambda Functions (automatic when SQS trigger is enabled)
# This will be created in lambda.tf after the SQS queues are created

# Local values for IAM role mapping
locals {
  # Map of service names to their IAM role ARNs
  service_role_map = {
    for name, config in var.services : name => (
      config.permissions != null ?
      aws_iam_role.ecs_custom_task_role[name].arn :
      aws_iam_role.ecs_shared_task_role[0].arn
    )
  }

  # Reference merged permissions from lambda.tf
  # (The lambda_merged_permissions is defined in lambda.tf locals)
}

# Data source for current AWS account (needed for SQS ARN construction)
data "aws_caller_identity" "current" {}