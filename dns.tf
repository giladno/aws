# Route53 and SSL Certificate Configuration

locals {
  # Extract the root domain (last two parts of the domain)
  # e.g., "api.example.com" -> "example.com", "example.com" -> "example.com"
  domain_parts = var.dns.domain != null ? split(".", var.dns.domain) : []
  root_domain = var.dns.domain != null ? (
    length(local.domain_parts) >= 2 ?
    join(".", slice(local.domain_parts, length(local.domain_parts) - 2, length(local.domain_parts))) :
    var.dns.domain
  ) : null
}

# Data source for existing Route53 hosted zone
data "aws_route53_zone" "main" {
  count        = var.dns.domain != null ? 1 : 0
  name         = local.root_domain
  private_zone = false
}

# ACM Certificate for the domain and all subdomains (for ALB in current region)
resource "aws_acm_certificate" "main" {
  count             = var.dns.domain != null ? 1 : 0
  domain_name       = var.dns.domain
  validation_method = "DNS"

  subject_alternative_names = [
    "*.${var.dns.domain}"
  ]

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.common_tags, {
    Name = var.dns.domain
  })
}

# ACM Certificate for CloudFront (must be in us-east-1)
# Only create if we need CloudFront AND current region is not already us-east-1
resource "aws_acm_certificate" "cloudfront" {
  provider          = aws.us_east_1
  count             = var.dns.domain != null && local.s3_enabled && var.s3.public != null && var.aws_region != "us-east-1" ? 1 : 0
  domain_name       = var.dns.domain
  validation_method = "DNS"

  subject_alternative_names = [
    "*.${var.dns.domain}"
  ]

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.common_tags, {
    Name = "${var.dns.domain}-cloudfront"
  })
}

# Route53 records for certificate validation (ALB certificate)
resource "aws_route53_record" "cert_validation" {
  for_each = var.dns.domain != null ? {
    for dvo in aws_acm_certificate.main[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.main[0].zone_id
}

# Route53 records for certificate validation (CloudFront certificate)
resource "aws_route53_record" "cert_validation_cloudfront" {
  for_each = var.dns.domain != null && local.s3_enabled && var.s3.public != null && var.aws_region != "us-east-1" ? {
    for dvo in aws_acm_certificate.cloudfront[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.main[0].zone_id
}

# Certificate validation for ALB certificate
resource "aws_acm_certificate_validation" "main" {
  count                   = var.dns.domain != null ? 1 : 0
  certificate_arn         = aws_acm_certificate.main[0].arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]

  timeouts {
    create = "5m"
  }
}

# Certificate validation for CloudFront certificate
resource "aws_acm_certificate_validation" "cloudfront" {
  provider                = aws.us_east_1
  count                   = var.dns.domain != null && local.s3_enabled && var.s3.public != null && var.aws_region != "us-east-1" ? 1 : 0
  certificate_arn         = aws_acm_certificate.cloudfront[0].arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation_cloudfront : record.fqdn]

  timeouts {
    create = "5m"
  }
}

# Route53 A record for root domain (CloudFront - only if CloudFront is enabled)
resource "aws_route53_record" "root" {
  count   = var.dns.domain != null && local.s3_enabled && var.s3.public != null ? 1 : 0
  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = var.dns.domain
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.main[0].domain_name
    zone_id                = aws_cloudfront_distribution.main[0].hosted_zone_id
    evaluate_target_health = false
  }
}

# Route53 A record for wildcard subdomains (Application Load Balancer)
# This will handle api.domain.com, admin.domain.com, and any other subdomains
# Only created when ALB is enabled
resource "aws_route53_record" "wildcard" {
  count   = var.dns.domain != null && local.alb_enabled ? 1 : 0
  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = "*.${var.dns.domain}"
  type    = "A"

  alias {
    name                   = aws_lb.main[0].dns_name
    zone_id                = aws_lb.main[0].zone_id
    evaluate_target_health = true
  }
}

# Route53 A record for www subdomain (redirect via ALB)
# Only created when ALB is enabled, domain is top-level, and www_redirect is enabled
resource "aws_route53_record" "www_alb" {
  count   = local.alb_enabled && local.subdomain_routing_allowed && local.www_redirect_enabled ? 1 : 0
  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = "www.${var.dns.domain}"
  type    = "A"

  alias {
    name                   = aws_lb.main[0].dns_name
    zone_id                = aws_lb.main[0].zone_id
    evaluate_target_health = true
  }
}

# Route53 A record for www subdomain (redirect via CloudFront)
# Only created when ALB is NOT enabled, domain is top-level, and www_redirect is enabled
resource "aws_route53_record" "www_cloudfront" {
  count   = !local.alb_enabled && local.subdomain_routing_allowed && local.www_redirect_enabled ? 1 : 0
  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = "www.${var.dns.domain}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.www_redirect[0].domain_name
    zone_id                = aws_cloudfront_distribution.www_redirect[0].hosted_zone_id
    evaluate_target_health = false
  }
}

# Route53 A records for service subdomains (when subdomain is defined and allowed)
# Only created when ALB is enabled
resource "aws_route53_record" "service_subdomains" {
  for_each = local.alb_enabled ? local.services_with_dns : {}

  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = "${each.value.http.subdomain}.${var.dns.domain}"
  type    = "A"

  alias {
    name                   = aws_lb.main[0].dns_name
    zone_id                = aws_lb.main[0].zone_id
    evaluate_target_health = true
  }
}

# Private hosted zone for local domain
resource "aws_route53_zone" "local" {
  name = "${var.name}.local"

  vpc {
    vpc_id = aws_vpc.main.id
  }

  tags = merge(local.common_tags, {
    Name = "${var.name}-local-zone"
  })
}
