# Local values for computed configuration
locals {
  # Use specified AZs or default to first 3 available
  availability_zones = length(var.vpc.availability_zones) > 0 ? var.vpc.availability_zones : slice(data.aws_availability_zones.available.names, 0, 3)

  # Compute subnet counts
  public_subnet_count   = var.vpc.public_subnets.enabled ? length(var.vpc.public_subnets.cidrs) : 0
  private_subnet_count  = var.vpc.private_subnets.enabled ? length(var.vpc.private_subnets.cidrs) : 0
  database_subnet_count = local.database_subnets_enabled ? length(var.vpc.database_subnets.cidrs) : 0

  # Generate subnet names if not provided
  public_subnet_names = length(var.vpc.public_subnets.names) > 0 ? var.vpc.public_subnets.names : [
    for i in range(local.public_subnet_count) : "${var.name}-public-${i + 1}"
  ]
  private_subnet_names = length(var.vpc.private_subnets.names) > 0 ? var.vpc.private_subnets.names : [
    for i in range(local.private_subnet_count) : "${var.name}-private-${i + 1}"
  ]
  database_subnet_names = length(var.vpc.database_subnets.names) > 0 ? var.vpc.database_subnets.names : [
    for i in range(local.database_subnet_count) : "${var.name}-database-${i + 1}"
  ]

  # NAT Gateway configuration
  create_nat_gateways = var.vpc.nat_gateway.enabled && local.private_subnet_count > 0
  # When single_nat_gateway is true, always create just 1 NAT gateway regardless of one_nat_gateway_per_az
  nat_gateway_count = local.create_nat_gateways ? (
    var.vpc.nat_gateway.single_nat_gateway ? 1 :
    var.vpc.nat_gateway.one_nat_gateway_per_az ? min(local.public_subnet_count, local.private_subnet_count) :
    local.private_subnet_count
  ) : 0

  # VPC Endpoints subnets (use private subnets if available, otherwise public)
  vpc_endpoint_subnet_ids = local.private_subnet_count > 0 ? aws_subnet.private[*].id : aws_subnet.public[*].id
}

# Data source for availability zones
data "aws_availability_zones" "available" {
  state = "available"
}

# VPC
resource "aws_vpc" "main" {
  cidr_block                       = var.vpc.cidr_block
  enable_dns_hostnames             = var.vpc.enable_dns_hostnames
  enable_dns_support               = var.vpc.enable_dns_support
  instance_tenancy                 = var.vpc.instance_tenancy
  assign_generated_ipv6_cidr_block = var.vpc.assign_generated_ipv6_cidr_block

  tags = merge(local.common_tags, var.vpc.vpc_tags, {
    Name = "${var.name}-vpc"
  })
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  count = var.vpc.internet_gateway.enabled ? 1 : 0

  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, var.vpc.igw_tags, var.vpc.internet_gateway.tags, {
    Name = "${var.name}-igw"
  })
}

# Public Subnets
resource "aws_subnet" "public" {
  count = local.public_subnet_count

  vpc_id                          = aws_vpc.main.id
  cidr_block                      = var.vpc.public_subnets.cidrs[count.index]
  availability_zone               = local.availability_zones[count.index % length(local.availability_zones)]
  map_public_ip_on_launch         = var.vpc.public_subnets.map_public_ip_on_launch
  assign_ipv6_address_on_creation = var.vpc.public_subnets.assign_ipv6_address_on_creation

  tags = merge(local.common_tags, var.vpc.public_subnet_tags, {
    Name = local.public_subnet_names[count.index]
    Type = "public"
    Tier = "public"
  })
}

# Private Subnets
resource "aws_subnet" "private" {
  count = local.private_subnet_count

  vpc_id                          = aws_vpc.main.id
  cidr_block                      = var.vpc.private_subnets.cidrs[count.index]
  availability_zone               = local.availability_zones[count.index % length(local.availability_zones)]
  assign_ipv6_address_on_creation = var.vpc.private_subnets.assign_ipv6_address_on_creation

  tags = merge(local.common_tags, var.vpc.private_subnet_tags, {
    Name = local.private_subnet_names[count.index]
    Type = "private"
    Tier = "private"
  })
}

# Database Subnets (isolated private subnets)
resource "aws_subnet" "database" {
  count = local.database_subnet_count

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.vpc.database_subnets.cidrs[count.index]
  availability_zone = local.availability_zones[count.index % length(local.availability_zones)]

  tags = merge(local.common_tags, var.vpc.database_subnet_tags, {
    Name = local.database_subnet_names[count.index]
    Type = "database"
    Tier = "database"
  })
}


# Elastic IPs for NAT Gateways
resource "aws_eip" "nat" {
  count = var.vpc.nat_gateway.reuse_nat_ips ? 0 : local.nat_gateway_count

  domain     = "vpc"
  depends_on = [aws_internet_gateway.main]

  tags = merge(local.common_tags, var.vpc.nat_eip_tags, {
    Name = "${var.name}-nat-eip-${count.index + 1}"
  })
}

# NAT Gateways
resource "aws_nat_gateway" "main" {
  count = local.nat_gateway_count

  allocation_id = var.vpc.nat_gateway.reuse_nat_ips ? var.vpc.nat_gateway.external_nat_ip_ids[count.index] : aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[var.vpc.nat_gateway.single_nat_gateway ? 0 : count.index].id

  tags = merge(local.common_tags, var.vpc.nat_gateway_tags, {
    Name = "${var.name}-nat-${count.index + 1}"
  })

  depends_on = [aws_internet_gateway.main]
}

# Route Table for Public Subnets
resource "aws_route_table" "public" {
  count = local.public_subnet_count > 0 ? 1 : 0

  vpc_id = aws_vpc.main.id

  dynamic "route" {
    for_each = var.vpc.internet_gateway.enabled ? [1] : []
    content {
      cidr_block = "0.0.0.0/0"
      gateway_id = aws_internet_gateway.main[0].id
    }
  }

  tags = merge(local.common_tags, {
    Name = "${var.name}-public-rt"
  })
}

# Route Table Associations for Public Subnets
resource "aws_route_table_association" "public" {
  count = local.public_subnet_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}

# Route Tables for Private Subnets
resource "aws_route_table" "private" {
  count = local.private_subnet_count

  vpc_id = aws_vpc.main.id

  dynamic "route" {
    for_each = local.create_nat_gateways ? [1] : []
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.main[var.vpc.nat_gateway.single_nat_gateway ? 0 : count.index].id
    }
  }

  tags = merge(local.common_tags, {
    Name = "${var.name}-private-rt-${count.index + 1}"
  })
}

# Route Table Associations for Private Subnets
resource "aws_route_table_association" "private" {
  count = local.private_subnet_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# Route Tables for Database Subnets (no NAT gateway access by default)
resource "aws_route_table" "database" {
  count = local.database_subnet_count

  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.name}-database-rt-${count.index + 1}"
  })
}

# Route Table Associations for Database Subnets
resource "aws_route_table_association" "database" {
  count = local.database_subnet_count

  subnet_id      = aws_subnet.database[count.index].id
  route_table_id = aws_route_table.database[count.index].id
}

# Security Group for VPC Endpoints
resource "aws_security_group" "vpc_endpoints" {
  count = var.vpc.endpoints.enabled ? 1 : 0

  name_prefix = "${var.name}-vpc-endpoints-"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port = 443
    to_port   = 443
    protocol  = "tcp"
    cidr_blocks = concat(
      aws_subnet.private[*].cidr_block,
      local.database_subnets_enabled ? aws_subnet.database[*].cidr_block : [],
      # Also allow access from public subnets (for bastion host)
      local.bastion_enabled ? aws_subnet.public[*].cidr_block : []
    )
    description = "HTTPS from private, database, and public subnets (for bastion)"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All outbound traffic"
  }

  tags = merge(local.common_tags, {
    Name = "${var.name}-vpc-endpoints-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# Gateway VPC Endpoints
resource "aws_vpc_endpoint" "s3" {
  count = var.vpc.endpoints.enabled && local.vpc_endpoints_defaults.s3_enabled ? 1 : 0

  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = length(var.vpc.endpoints.s3.route_table_ids) > 0 ? var.vpc.endpoints.s3.route_table_ids : concat(
    aws_route_table.private[*].id,
    aws_route_table.database[*].id,
    local.public_subnet_count > 0 ? [aws_route_table.public[0].id] : []
  )

  policy = var.vpc.endpoints.s3.policy

  tags = merge(local.common_tags, {
    Name = "${var.name}-s3-endpoint"
  })
}


# Interface VPC Endpoints
resource "aws_vpc_endpoint" "ecr_api" {
  count = var.vpc.endpoints.enabled && local.vpc_endpoints_defaults.ecr_api_enabled ? 1 : 0

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = length(var.vpc.endpoints.ecr_api.subnet_ids) > 0 ? var.vpc.endpoints.ecr_api.subnet_ids : local.vpc_endpoint_subnet_ids
  security_group_ids  = length(var.vpc.endpoints.ecr_api.security_group_ids) > 0 ? var.vpc.endpoints.ecr_api.security_group_ids : [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = var.vpc.endpoints.ecr_api.private_dns_enabled
  policy              = var.vpc.endpoints.ecr_api.policy

  tags = merge(local.common_tags, {
    Name = "${var.name}-ecr-api-endpoint"
  })
}

resource "aws_vpc_endpoint" "ecr_dkr" {
  count = var.vpc.endpoints.enabled && local.vpc_endpoints_defaults.ecr_dkr_enabled ? 1 : 0

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = length(var.vpc.endpoints.ecr_dkr.subnet_ids) > 0 ? var.vpc.endpoints.ecr_dkr.subnet_ids : local.vpc_endpoint_subnet_ids
  security_group_ids  = length(var.vpc.endpoints.ecr_dkr.security_group_ids) > 0 ? var.vpc.endpoints.ecr_dkr.security_group_ids : [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = var.vpc.endpoints.ecr_dkr.private_dns_enabled
  policy              = var.vpc.endpoints.ecr_dkr.policy

  tags = merge(local.common_tags, {
    Name = "${var.name}-ecr-dkr-endpoint"
  })
}

resource "aws_vpc_endpoint" "logs" {
  count = var.vpc.endpoints.enabled && (var.vpc.endpoints.logs.enabled != null ? var.vpc.endpoints.logs.enabled : (local.fargate_enabled || local.rds_enabled)) ? 1 : 0

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.logs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = length(var.vpc.endpoints.logs.subnet_ids) > 0 ? var.vpc.endpoints.logs.subnet_ids : local.vpc_endpoint_subnet_ids
  security_group_ids  = length(var.vpc.endpoints.logs.security_group_ids) > 0 ? var.vpc.endpoints.logs.security_group_ids : [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = var.vpc.endpoints.logs.private_dns_enabled
  policy              = var.vpc.endpoints.logs.policy

  tags = merge(local.common_tags, {
    Name = "${var.name}-logs-endpoint"
  })
}

resource "aws_vpc_endpoint" "secretsmanager" {
  count = var.vpc.endpoints.enabled && (var.vpc.endpoints.secretsmanager.enabled != null ? var.vpc.endpoints.secretsmanager.enabled : (local.fargate_enabled || local.rds_enabled || local.bastion_enabled)) ? 1 : 0

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = length(var.vpc.endpoints.secretsmanager.subnet_ids) > 0 ? var.vpc.endpoints.secretsmanager.subnet_ids : local.vpc_endpoint_subnet_ids
  security_group_ids  = length(var.vpc.endpoints.secretsmanager.security_group_ids) > 0 ? var.vpc.endpoints.secretsmanager.security_group_ids : [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = var.vpc.endpoints.secretsmanager.private_dns_enabled
  policy              = var.vpc.endpoints.secretsmanager.policy

  tags = merge(local.common_tags, {
    Name = "${var.name}-secretsmanager-endpoint"
  })
}

resource "aws_vpc_endpoint" "kms" {
  count = var.vpc.endpoints.enabled && local.vpc_endpoints_defaults.kms_enabled ? 1 : 0

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.kms"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = length(var.vpc.endpoints.kms.subnet_ids) > 0 ? var.vpc.endpoints.kms.subnet_ids : local.vpc_endpoint_subnet_ids
  security_group_ids  = length(var.vpc.endpoints.kms.security_group_ids) > 0 ? var.vpc.endpoints.kms.security_group_ids : [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = var.vpc.endpoints.kms.private_dns_enabled
  policy              = var.vpc.endpoints.kms.policy

  tags = merge(local.common_tags, {
    Name = "${var.name}-kms-endpoint"
  })
}

# Custom VPC Endpoints
resource "aws_vpc_endpoint" "custom" {
  for_each = var.vpc.endpoints.enabled ? var.vpc.endpoints.endpoints : {}

  vpc_id            = aws_vpc.main.id
  service_name      = each.value.service_name
  vpc_endpoint_type = each.value.vpc_endpoint_type

  # Interface endpoint configuration
  subnet_ids          = each.value.vpc_endpoint_type == "Interface" ? (length(each.value.subnet_ids) > 0 ? each.value.subnet_ids : local.vpc_endpoint_subnet_ids) : null
  security_group_ids  = each.value.vpc_endpoint_type == "Interface" ? (length(each.value.security_group_ids) > 0 ? each.value.security_group_ids : [aws_security_group.vpc_endpoints[0].id]) : null
  private_dns_enabled = each.value.vpc_endpoint_type == "Interface" ? each.value.private_dns_enabled : null

  # Gateway endpoint configuration
  route_table_ids = each.value.vpc_endpoint_type == "Gateway" ? (length(each.value.route_table_ids) > 0 ? each.value.route_table_ids : concat(
    aws_route_table.private[*].id,
    aws_route_table.database[*].id,
    local.public_subnet_count > 0 ? [aws_route_table.public[0].id] : []
  )) : null

  policy = each.value.policy

  tags = merge(local.common_tags, {
    Name = "${var.name}-${each.key}-endpoint"
  })
}


# VPC Flow Logs
resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  count = var.vpc.flow_logs.enabled && var.vpc.flow_logs.log_destination_type == "cloud-watch-logs" && var.vpc.flow_logs.log_destination == null ? 1 : 0

  name              = "/aws/vpc/flowlogs/${var.name}"
  retention_in_days = var.vpc.flow_logs.log_retention_days

  # Encryption configuration
  kms_key_id = (var.logging.kms != null && var.logging.kms != false && var.logging.kms != true) ? var.logging.kms : null

  tags = merge(local.common_tags, var.vpc.flow_logs.tags)
}

resource "aws_iam_role" "vpc_flow_logs" {
  count = var.vpc.flow_logs.enabled && var.vpc.flow_logs.log_destination_type == "cloud-watch-logs" && var.vpc.flow_logs.iam_role_arn == null ? 1 : 0

  name = "${var.name}-vpc-flow-logs"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "vpc-flow-logs.amazonaws.com"
        }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "vpc_flow_logs" {
  count = var.vpc.flow_logs.enabled && var.vpc.flow_logs.log_destination_type == "cloud-watch-logs" && var.vpc.flow_logs.iam_role_arn == null ? 1 : 0

  name = "${var.name}-vpc-flow-logs"
  role = aws_iam_role.vpc_flow_logs[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams"
        ]
        Effect = "Allow"
        Resource = [
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/vpc/flowlogs/${var.name}:*",
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/vpc/flowlogs/${var.name}"
        ]
      }
    ]
  })
}

resource "aws_flow_log" "vpc" {
  count = var.vpc.flow_logs.enabled ? 1 : 0

  iam_role_arn             = var.vpc.flow_logs.iam_role_arn != null ? var.vpc.flow_logs.iam_role_arn : (var.vpc.flow_logs.log_destination_type == "cloud-watch-logs" ? aws_iam_role.vpc_flow_logs[0].arn : null)
  log_destination          = var.vpc.flow_logs.log_destination != null ? var.vpc.flow_logs.log_destination : (var.vpc.flow_logs.log_destination_type == "cloud-watch-logs" ? aws_cloudwatch_log_group.vpc_flow_logs[0].arn : null)
  log_destination_type     = var.vpc.flow_logs.log_destination_type
  log_format               = var.vpc.flow_logs.log_format
  traffic_type             = var.vpc.flow_logs.traffic_type
  vpc_id                   = aws_vpc.main.id
  max_aggregation_interval = var.vpc.flow_logs.max_aggregation_interval

  tags = merge(local.common_tags, var.vpc.flow_logs.tags, {
    Name = "${var.name}-vpc-flow-logs"
  })
}