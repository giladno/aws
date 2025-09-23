# Origin Access Control for S3 (only if S3 public is enabled)
resource "aws_cloudfront_origin_access_control" "main" {
  count = local.s3_enabled && var.s3.public != null ? 1 : 0

  name                              = "${var.name}-s3-oac"
  description                       = "OAC for S3 bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Main CloudFront Distribution for root domain
resource "aws_cloudfront_distribution" "main" {
  count = local.s3_enabled && var.s3.public != null ? 1 : 0

  # S3 Origin for static content
  origin {
    domain_name              = aws_s3_bucket.main[0].bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.main[0].id
    origin_id                = "S3-${aws_s3_bucket.main[0].id}"
    origin_path              = var.s3.public
  }

  # API Gateway Origins for Lambda functions with CloudFront routing
  dynamic "origin" {
    for_each = local.lambda_with_cloudfront
    content {
      domain_name = regex("^https://([^/]+)", module.lambda_functions[origin.key].api_gateway_url)[0] # API Gateway regional domain
      origin_id   = "Lambda-${origin.key}"
      # No origin_path needed - API Gateway HTTP API handles stage internally

      custom_origin_config {
        http_port              = 80
        https_port             = 443
        origin_protocol_policy = "https-only"
        origin_ssl_protocols   = ["TLSv1.2"]
      }

      # Forward original viewer host as custom header
      custom_header {
        name  = "X-Forwarded-Host"
        value = var.dns.domain
      }
    }
  }

  enabled             = true
  is_ipv6_enabled     = true
  comment             = "${var.name} CloudFront Distribution"
  default_root_object = var.s3.default_root_object

  # Cache behaviors for Lambda functions (must come before default)
  dynamic "ordered_cache_behavior" {
    for_each = local.lambda_with_cloudfront
    content {
      path_pattern           = replace("${trimsuffix(ordered_cache_behavior.value.triggers.http.path_pattern, "/")}*", "/{proxy+}*", "/*")
      allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
      cached_methods         = ["GET", "HEAD", "OPTIONS"]
      target_origin_id       = "Lambda-${ordered_cache_behavior.key}"
      viewer_protocol_policy = "redirect-to-https"
      compress               = true

      forwarded_values {
        # Query string caching configuration
        query_string = try(ordered_cache_behavior.value.triggers.http.cache.cache_key.query_strings.behavior, "all") != "none"
        
        # Headers configuration - use cache key headers if specified, otherwise minimal set
        headers = (
          try(ordered_cache_behavior.value.triggers.http.cache.cache_key.headers.behavior, "none") == "whitelist" ? 
            concat(
              ["Accept", "CloudFront-Forwarded-Proto", "User-Agent", "X-Forwarded-For"],
              try(ordered_cache_behavior.value.triggers.http.cache.cache_key.headers.items, [])
            ) : 
            (try(ordered_cache_behavior.value.triggers.http.cache.cache_key.headers.behavior, "none") == "none" ?
              ["Accept", "CloudFront-Forwarded-Proto", "User-Agent", "X-Forwarded-For"] :
              ["*"])
        )
        
        cookies {
          forward = (
            try(ordered_cache_behavior.value.triggers.http.cache.cache_key.cookies.behavior, "none") == "none" ? "none" :
            (try(ordered_cache_behavior.value.triggers.http.cache.cache_key.cookies.behavior, "none") == "all" ? "all" : "whitelist")
          )
          
          # Only include whitelisted_names when forward = "whitelist"
          whitelisted_names = (
            try(ordered_cache_behavior.value.triggers.http.cache.cache_key.cookies.behavior, "none") == "whitelist" ?
            try(ordered_cache_behavior.value.triggers.http.cache.cache_key.cookies.items, []) : []
          )
        }

        # Query string whitelist when behavior is "whitelist"
        query_string_cache_keys = (
          try(ordered_cache_behavior.value.triggers.http.cache.cache_key.query_strings.behavior, "all") == "whitelist" ?
          try(ordered_cache_behavior.value.triggers.http.cache.cache_key.query_strings.items, []) : []
        )
      }

      # Use cache configuration from Lambda trigger, fallback to no caching
      min_ttl     = try(ordered_cache_behavior.value.triggers.http.cache.enabled, false) ? try(ordered_cache_behavior.value.triggers.http.cache.min_ttl, 0) : 0
      default_ttl = try(ordered_cache_behavior.value.triggers.http.cache.enabled, false) ? try(ordered_cache_behavior.value.triggers.http.cache.default_ttl, 86400) : 0
      max_ttl     = try(ordered_cache_behavior.value.triggers.http.cache.enabled, false) ? try(ordered_cache_behavior.value.triggers.http.cache.max_ttl, 31536000) : 86400
    }
  }

  # Default cache behavior for static assets (S3)
  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3-${aws_s3_bucket.main[0].id}"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
      headers = ["Origin", "Access-Control-Request-Headers", "Access-Control-Request-Method"]
    }

    viewer_protocol_policy = var.cloudfront.viewer_protocol_policy
    min_ttl                = var.cloudfront.min_ttl
    default_ttl            = var.cloudfront.default_ttl
    max_ttl                = var.cloudfront.max_ttl

    compress = var.cloudfront.compress
  }

  # SPA custom error pages (redirect 404s to the SPA file)
  dynamic "custom_error_response" {
    for_each = local.s3_spa_target != null ? [1] : []
    content {
      error_code         = 404
      response_code      = 200
      response_page_path = "/${local.s3_spa_target}"
    }
  }

  dynamic "custom_error_response" {
    for_each = local.s3_spa_target != null ? [1] : []
    content {
      error_code         = 403
      response_code      = 200
      response_page_path = "/${local.s3_spa_target}"
    }
  }


  # Geographic restrictions
  restrictions {
    geo_restriction {
      restriction_type = var.cloudfront.geo_restriction_type
      locations        = var.cloudfront.geo_restriction_locations
    }
  }

  # SSL Certificate
  viewer_certificate {
    acm_certificate_arn = var.dns.domain != null ? (
      var.aws_region == "us-east-1" ?
      data.aws_acm_certificate.main[0].arn :
      data.aws_acm_certificate.cloudfront[0].arn
    ) : null
    ssl_support_method             = var.dns.domain != null ? var.cloudfront.ssl_support_method : null
    minimum_protocol_version       = var.dns.domain != null ? var.cloudfront.minimum_protocol_version : null
    cloudfront_default_certificate = var.dns.domain != null ? false : true
  }

  # Custom domain aliases (root domain only)
  aliases = var.dns.domain != null ? [var.dns.domain] : []

  # Price class configuration
  price_class = var.cloudfront.price_class

  tags = merge(local.common_tags, {
    Name = "${var.name}-cloudfront"
  })
}


# Output CloudFront details
output "cloudfront_distribution_id" {
  value       = local.s3_enabled && var.s3.public != null ? aws_cloudfront_distribution.main[0].id : null
  description = "CloudFront Distribution ID"
}

output "cloudfront_domain_name" {
  value       = local.s3_enabled && var.s3.public != null ? aws_cloudfront_distribution.main[0].domain_name : null
  description = "CloudFront Distribution Domain Name"
}

# S3 bucket for www redirect (when ALB is not enabled)
resource "aws_s3_bucket" "www_redirect" {
  count  = !local.alb_enabled && local.subdomain_routing_allowed && local.www_redirect_enabled ? 1 : 0
  bucket = "www.${var.dns.domain}"

  tags = merge(local.common_tags, {
    Name = "${var.name}-www-redirect"
  })
}

# S3 bucket website configuration for www redirect
resource "aws_s3_bucket_website_configuration" "www_redirect" {
  count  = !local.alb_enabled && local.subdomain_routing_allowed && local.www_redirect_enabled ? 1 : 0
  bucket = aws_s3_bucket.www_redirect[0].id

  redirect_all_requests_to {
    host_name = var.dns.domain
    protocol  = "https"
  }
}

# S3 bucket public access block for www redirect
resource "aws_s3_bucket_public_access_block" "www_redirect" {
  count  = !local.alb_enabled && local.subdomain_routing_allowed && local.www_redirect_enabled ? 1 : 0
  bucket = aws_s3_bucket.www_redirect[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Origin Access Control for www redirect S3 bucket
resource "aws_cloudfront_origin_access_control" "www_redirect" {
  count = !local.alb_enabled && local.subdomain_routing_allowed && local.www_redirect_enabled ? 1 : 0

  name                              = "${var.name}-www-redirect-oac"
  description                       = "OAC for www redirect S3 bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# CloudFront Distribution for www redirect
resource "aws_cloudfront_distribution" "www_redirect" {
  count = !local.alb_enabled && local.subdomain_routing_allowed && local.www_redirect_enabled ? 1 : 0

  origin {
    domain_name              = aws_s3_bucket.www_redirect[0].bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.www_redirect[0].id
    origin_id                = "S3-${aws_s3_bucket.www_redirect[0].id}"
  }

  enabled         = true
  is_ipv6_enabled = true
  comment         = "${var.name} www redirect CloudFront Distribution"

  # Cache behavior
  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "S3-${aws_s3_bucket.www_redirect[0].id}"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    min_ttl     = 0
    default_ttl = 86400
    max_ttl     = 31536000
  }

  # Geographic restrictions
  restrictions {
    geo_restriction {
      restriction_type = var.cloudfront.geo_restriction_type
      locations        = var.cloudfront.geo_restriction_locations
    }
  }

  # SSL Certificate
  viewer_certificate {
    acm_certificate_arn      = data.aws_acm_certificate.main[0].arn
    ssl_support_method       = var.cloudfront.ssl_support_method
    minimum_protocol_version = var.cloudfront.minimum_protocol_version
  }

  # Custom domain aliases (www subdomain)
  aliases = ["www.${var.dns.domain}"]

  # Price class configuration
  price_class = var.cloudfront.price_class

  tags = merge(local.common_tags, {
    Name = "${var.name}-www-redirect-cloudfront"
  })
}

# S3 Bucket Policy for www redirect CloudFront OAC
resource "aws_s3_bucket_policy" "www_redirect" {
  count = !local.alb_enabled && local.subdomain_routing_allowed && local.www_redirect_enabled ? 1 : 0

  bucket = aws_s3_bucket.www_redirect[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudFrontServicePrincipal"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.www_redirect[0].arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.www_redirect[0].arn
          }
        }
      }
    ]
  })
}

output "www_redirect_method" {
  value = var.dns.domain != null && local.www_redirect_enabled ? (
    local.alb_enabled ? "ALB listener rule" : "S3 + CloudFront redirect"
  ) : null
  description = "Method used for www redirect"
}
