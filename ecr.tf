# Amazon Elastic Container Registry (ECR) for container images
# This module creates ECR repositories when services use source for local builds

# ECR Repository (conditional - only when services use source)
resource "aws_ecr_repository" "main" {
  count = local.ecr_enabled ? 1 : 0

  name                 = "${var.name}-ecr"
  image_tag_mutability = var.ecr.image_tag_mutability

  # Enable image scanning for security
  image_scanning_configuration {
    scan_on_push = var.ecr.scan_on_push
  }

  # Encryption configuration
  encryption_configuration {
    encryption_type = var.ecr.encryption_type
    kms_key         = var.ecr.encryption_type == "KMS" ? var.ecr.kms_key : null
  }

  tags = merge(local.common_tags, {
    Name = "${var.name}-ecr"
  })
}

# ECR Lifecycle Policy to manage image retention with service-specific rules
resource "aws_ecr_lifecycle_policy" "main" {
  count      = local.ecr_enabled && var.ecr.lifecycle_policy.enabled ? 1 : 0
  repository = aws_ecr_repository.main[0].name

  policy = jsonencode({
    rules = concat(
      # Service-specific lifecycle rules (higher priority)
      [
        for priority, service_rule in local.ecr_service_lifecycle_rules : {
          rulePriority = priority + 1
          description  = "Keep last ${service_rule.keep_count} images for service: ${service_rule.service_name}"
          selection = {
            tagStatus     = "tagged"
            tagPrefixList = ["${service_rule.service_name}-"]
            countType     = "imageCountMoreThan"
            countNumber   = service_rule.keep_count
          }
          action = {
            type = "expire"
          }
        }
      ],
      # Global fallback rule for any remaining images (lowest priority)
      [{
        rulePriority = length(local.ecr_service_lifecycle_rules) + 100
        description  = "Global fallback: Keep last ${var.ecr.lifecycle_policy.global_defaults.keep_count} images for unmatched tags"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.ecr.lifecycle_policy.global_defaults.keep_count
        }
        action = {
          type = "expire"
        }
      }]
    )
  })
}

# ECR Repository Policy for cross-account access (if needed)
resource "aws_ecr_repository_policy" "main" {
  count      = local.ecr_enabled ? 1 : 0
  repository = aws_ecr_repository.main[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowPull"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability"
        ]
      }
    ]
  })
}

# Output ECR details
output "ecr_repository_url" {
  value       = local.ecr_enabled ? aws_ecr_repository.main[0].repository_url : null
  description = "ECR Repository URL for container images"
}

output "ecr_repository_name" {
  value       = local.ecr_enabled ? aws_ecr_repository.main[0].name : null
  description = "ECR Repository Name"
}