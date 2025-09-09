# SES Configuration - Simple Email Service setup with domain verification

# Local values for SES
locals {
  # ses_enabled now defined in locals.tf
  ses_domain  = local.ses_enabled ? var.dns.domain : null
}

# SES Domain Identity
resource "aws_ses_domain_identity" "main" {
  count = local.ses_enabled ? 1 : 0

  domain = local.ses_domain
}

# SES Domain Verification Record (TXT record)
resource "aws_route53_record" "ses_verification" {
  count = local.ses_enabled && var.ses.domain_verification.create_verification_record ? 1 : 0

  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = "_amazonses.${local.ses_domain}"
  type    = "TXT"
  ttl     = 600
  records = [aws_ses_domain_identity.main[0].verification_token]
}

# Wait for domain verification
resource "aws_ses_domain_identity_verification" "main" {
  count = local.ses_enabled && var.ses.domain_verification.create_verification_record ? 1 : 0

  domain     = aws_ses_domain_identity.main[0].id
  depends_on = [aws_route53_record.ses_verification]

  timeouts {
    create = "5m"
  }
}

# SES DKIM Configuration
resource "aws_ses_domain_dkim" "main" {
  count = local.ses_enabled ? 1 : 0

  domain = aws_ses_domain_identity.main[0].domain
}

# DKIM Records (CNAME records for authentication)
resource "aws_route53_record" "ses_dkim" {
  count = local.ses_enabled && var.ses.domain_verification.create_dkim_records ? 3 : 0

  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = "${aws_ses_domain_dkim.main[0].dkim_tokens[count.index]}._domainkey.${local.ses_domain}"
  type    = "CNAME"
  ttl     = 600
  records = ["${aws_ses_domain_dkim.main[0].dkim_tokens[count.index]}.dkim.amazonses.com"]
}

# SES Configuration Set (optional)
resource "aws_ses_configuration_set" "main" {
  count = local.ses_enabled && var.ses.configuration_set.enabled ? 1 : 0

  name = "${var.name}-ses-config"

  delivery_options {
    tls_policy = var.ses.sending_config.delivery_options
  }
}

# Reputation tracking is no longer supported as a separate resource in AWS provider
# It's now part of the configuration set itself

# Event Destinations for Configuration Set
resource "aws_ses_event_destination" "bounce" {
  count = local.ses_enabled && var.ses.configuration_set.enabled && var.ses.bounce_notifications.bounce_topic != null ? 1 : 0

  name                   = "${var.name}-bounces"
  configuration_set_name = aws_ses_configuration_set.main[0].name
  enabled                = true
  matching_types         = ["bounce"]

  sns_destination {
    topic_arn = var.ses.bounce_notifications.bounce_topic
  }
}

resource "aws_ses_event_destination" "complaint" {
  count = local.ses_enabled && var.ses.configuration_set.enabled && var.ses.bounce_notifications.complaint_topic != null ? 1 : 0

  name                   = "${var.name}-complaints"
  configuration_set_name = aws_ses_configuration_set.main[0].name
  enabled                = true
  matching_types         = ["complaint"]

  sns_destination {
    topic_arn = var.ses.bounce_notifications.complaint_topic
  }
}

resource "aws_ses_event_destination" "delivery" {
  count = local.ses_enabled && var.ses.configuration_set.enabled && var.ses.bounce_notifications.delivery_topic != null ? 1 : 0

  name                   = "${var.name}-deliveries"
  configuration_set_name = aws_ses_configuration_set.main[0].name
  enabled                = true
  matching_types         = ["delivery"]

  sns_destination {
    topic_arn = var.ses.bounce_notifications.delivery_topic
  }
}

# SES Email Address Verification (for development/testing)
resource "aws_ses_email_identity" "verified_emails" {
  for_each = local.ses_enabled ? toset(var.ses.verified_emails) : toset([])

  email = each.value
}

# Use the existing Route53 zone data source from dns.tf

# Outputs for SES
output "ses_domain_identity" {
  value       = local.ses_enabled ? aws_ses_domain_identity.main[0].arn : null
  description = "SES domain identity ARN"
}

output "ses_configuration_set" {
  value       = local.ses_enabled && var.ses.configuration_set.enabled ? aws_ses_configuration_set.main[0].name : null
  description = "SES configuration set name"
}

output "ses_domain_verification_status" {
  value       = local.ses_enabled && var.ses.domain_verification.create_verification_record ? aws_ses_domain_identity_verification.main[0].id : null
  description = "SES domain verification status"
}

output "ses_verified_emails" {
  value       = local.ses_enabled ? [for email in aws_ses_email_identity.verified_emails : email.email] : []
  description = "List of verified email addresses"
}