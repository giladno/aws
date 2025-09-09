# S3 Bucket (conditional)
resource "aws_s3_bucket" "main" {
  count = local.s3_enabled ? 1 : 0

  bucket = var.s3.bucket_name != null ? var.s3.bucket_name : "${var.name}-s3"

  tags = merge(local.common_tags, {
    Name = var.s3.bucket_name != null ? var.s3.bucket_name : "${var.name}-s3"
  })
}

# S3 Bucket Server-side Encryption
resource "aws_s3_bucket_server_side_encryption_configuration" "main" {
  count  = local.s3_enabled && var.s3.kms != null && var.s3.kms != false ? 1 : 0
  bucket = aws_s3_bucket.main[0].id

  rule {
    apply_server_side_encryption_by_default {
      # Determine algorithm based on kms value
      sse_algorithm = var.s3.kms == "AES256" ? "AES256" : "aws:kms"

      # Set KMS key ID for customer-managed keys (not for true or AES256)
      kms_master_key_id = (
        var.s3.kms != "AES256" && var.s3.kms != true ? var.s3.kms : null
      )
    }
    bucket_key_enabled = var.s3.kms != "AES256" # Only enable bucket key for KMS encryption
  }
}

# S3 Bucket Versioning Configuration
resource "aws_s3_bucket_versioning" "main" {
  count  = local.s3_enabled ? 1 : 0
  bucket = aws_s3_bucket.main[0].id

  versioning_configuration {
    status = var.s3.versioning ? "Enabled" : "Suspended"
  }
}

# S3 Bucket Public Access Block (secure - no public access)
resource "aws_s3_bucket_public_access_block" "main" {
  count  = local.s3_enabled ? 1 : 0
  bucket = aws_s3_bucket.main[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# S3 Bucket Lifecycle Configuration
resource "aws_s3_bucket_lifecycle_configuration" "main" {
  count  = local.s3_enabled ? 1 : 0
  bucket = aws_s3_bucket.main[0].id

  # Default lifecycle rule for cost optimization
  rule {
    id     = "default_lifecycle"
    status = "Enabled"

    filter {}

    # Transition to IA after specified days
    dynamic "transition" {
      for_each = var.s3.lifecycle_rules.transition_to_ia_days != null ? [1] : []
      content {
        days          = var.s3.lifecycle_rules.transition_to_ia_days
        storage_class = "STANDARD_IA"
      }
    }

    # Transition to Glacier after specified days
    dynamic "transition" {
      for_each = var.s3.lifecycle_rules.transition_to_glacier_days != null ? [1] : []
      content {
        days          = var.s3.lifecycle_rules.transition_to_glacier_days
        storage_class = "GLACIER_IR"
      }
    }

    # Expiration rule
    dynamic "expiration" {
      for_each = var.s3.lifecycle_rules.expiration_days != null ? [1] : []
      content {
        days = var.s3.lifecycle_rules.expiration_days
      }
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = var.s3.lifecycle_rules.abort_incomplete_multipart_days
    }
  }

  # Additional custom lifecycle rules
  dynamic "rule" {
    for_each = var.s3.lifecycle_rules.rules
    content {
      id     = rule.value.id
      status = rule.value.status

      # Filter configuration
      filter {
        dynamic "and" {
          for_each = (rule.value.filter.prefix != null || length(rule.value.filter.tags) > 0) ? [1] : []
          content {
            prefix = rule.value.filter.prefix
            tags   = rule.value.filter.tags
          }
        }
      }

      # Transition rules
      dynamic "transition" {
        for_each = rule.value.transitions
        content {
          days          = transition.value.days
          storage_class = transition.value.storage_class
        }
      }

      # Expiration rule
      dynamic "expiration" {
        for_each = rule.value.expiration_days != null ? [rule.value.expiration_days] : []
        content {
          days = expiration.value
        }
      }

      # Multipart upload cleanup
      dynamic "abort_incomplete_multipart_upload" {
        for_each = rule.value.abort_incomplete_multipart_days != null ? [rule.value.abort_incomplete_multipart_days] : []
        content {
          days_after_initiation = abort_incomplete_multipart_upload.value
        }
      }
    }
  }
}

# S3 Bucket Policy for CloudFront OAC access and encryption enforcement
resource "aws_s3_bucket_policy" "main" {
  count  = local.s3_enabled && var.s3.public != null ? 1 : 0
  bucket = aws_s3_bucket.main[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudFrontOACAccess"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.main[0].arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = try(aws_cloudfront_distribution.main[0].arn, "")
          }
        }
      },
      {
        Sid       = "RequireExplicitAES256ForPublicPrefix"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.main[0].arn}${var.s3.public}/*"
        Condition = {
          StringNotEquals = {
            "s3:x-amz-server-side-encryption" = "AES256"
          }
        }
      }
    ]
  })

  depends_on = [
    aws_cloudfront_distribution.main
  ]
}

# S3 Bucket CORS Configuration for web assets (only when public static assets are enabled)
resource "aws_s3_bucket_cors_configuration" "main" {
  count  = local.s3_enabled && var.s3.public != null ? 1 : 0
  bucket = aws_s3_bucket.main[0].id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "HEAD"]
    allowed_origins = var.dns.domain != null ? [
      "https://${var.dns.domain}",
      "https://*.${var.dns.domain}"
    ] : length(var.s3.cors_allowed_origins) > 0 ? var.s3.cors_allowed_origins : []
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}
