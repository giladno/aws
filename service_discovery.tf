# Service Discovery Private DNS Namespace
resource "aws_service_discovery_private_dns_namespace" "main" {
  count = length(local.services_with_local_dns) > 0 ? 1 : 0

  name = "services.${var.name}.local"
  vpc  = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.name}-service-discovery"
  })
}

# Local variables for service discovery
locals {
  # Services that need local DNS
  services_with_local_dns = {
    for name, config in var.services : name => {
      dns_name = config.local == true ? name : (
        config.local != null && config.local != false ? tostring(config.local) : null
      )
      port = config.http != null ? config.http.port : null
    }
    if config.local != null && config.local != false
  }
}

# Service Discovery Services
resource "aws_service_discovery_service" "services" {
  for_each = local.services_with_local_dns

  name = each.value.dns_name

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.main[0].id

    dns_records {
      ttl  = 10
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }


  tags = merge(local.common_tags, {
    Name    = "${var.name}-${each.key}-discovery"
    Service = each.key
  })
}