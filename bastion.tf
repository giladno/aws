# Bastion Host Configuration

# Data source for latest Amazon Linux 2023 ARM64 AMI
data "aws_ami" "amazon_linux" {
  count = local.bastion_enabled ? 1 : 0

  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-arm64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

# Generate TLS private key for bastion
resource "tls_private_key" "bastion" {
  count = local.bastion_enabled ? 1 : 0

  algorithm = "ED25519"
}

# Store private key in Secrets Manager
resource "aws_secretsmanager_secret" "bastion_private_key" {
  count = local.bastion_enabled ? 1 : 0

  name                    = "${var.name}-bastion-private-key"
  description             = "Private key for bastion host SSH access (shared across all bastion instances)"
  recovery_window_in_days = 7

  tags = local.common_tags
}

resource "aws_secretsmanager_secret_version" "bastion_private_key" {
  count = local.bastion_enabled ? 1 : 0

  secret_id = aws_secretsmanager_secret.bastion_private_key[0].id
  secret_string = jsonencode({
    private_key = tls_private_key.bastion[0].private_key_openssh
    public_key  = tls_private_key.bastion[0].public_key_openssh
    key_type    = "ED25519"
  })

  lifecycle {
    replace_triggered_by = [tls_private_key.bastion[0]]
  }
}

# Key pair for bastion hosts using shared generated public key
resource "aws_key_pair" "bastion" {
  count = local.bastion_enabled ? 1 : 0

  key_name   = "${var.name}-bastion-key"
  public_key = tls_private_key.bastion[0].public_key_openssh

  tags = merge(local.common_tags, {
    Name = "${var.name}-bastion-key"
  })
}

# Security group for each bastion host
resource "aws_security_group" "bastion" {
  for_each = local.bastion_configs_enabled

  name_prefix = "${var.name}-${each.value.name}-"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = each.value.allowed_cidr_blocks
    description = "SSH access from configured CIDR blocks for ${each.value.name}"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All outbound traffic"
  }

  tags = merge(local.common_tags, {
    Name = "${var.name}-${each.value.name}-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# Security group rule to allow all bastion instances access to RDS
resource "aws_security_group_rule" "bastion_to_rds" {
  for_each = local.bastion_enabled && local.rds_enabled ? local.bastion_configs_enabled : {}

  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.bastion[each.key].id
  security_group_id        = aws_security_group.rds[0].id
  description              = "PostgreSQL access from bastion ${each.value.name}"
}

# Security group rule to allow all bastion instances access to RDS Proxy (conditional)
resource "aws_security_group_rule" "bastion_to_rds_proxy" {
  for_each = local.bastion_enabled && local.rds_enabled && var.rds.proxy ? local.bastion_configs_enabled : {}

  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.bastion[each.key].id
  security_group_id        = aws_security_group.rds_proxy[0].id
  description              = "PostgreSQL access from bastion ${each.value.name} to RDS Proxy"
}

# Create a dedicated security group for ECS services that bastion can access
resource "aws_security_group" "ecs_bastion_access" {
  count = local.bastion_enabled && length(var.services) > 0 ? 1 : 0

  name_prefix = "${var.name}-ecs-bastion-access-"
  vpc_id      = aws_vpc.main.id
  description = "Security group for ECS services accessible from all bastion instances"

  # Allow ingress from all bastion instances on standard web ports
  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = values(aws_security_group.bastion)[*].id
    description     = "HTTP from all bastion instances"
  }

  ingress {
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = values(aws_security_group.bastion)[*].id
    description     = "HTTPS from all bastion instances"
  }

  # Allow ingress from all bastion instances on ephemeral/application ports (1024+)
  ingress {
    from_port       = 1024
    to_port         = 65535
    protocol        = "tcp"
    security_groups = values(aws_security_group.bastion)[*].id
    description     = "Application ports from all bastion instances"
  }

  tags = merge(local.common_tags, {
    Name = "${var.name}-ecs-bastion-access-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# IAM role for bastion host
resource "aws_iam_role" "bastion" {
  count = local.bastion_enabled ? 1 : 0

  name = "${var.name}-bastion-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = local.common_tags
}

# IAM policy for bastion to access Secrets Manager
resource "aws_iam_role_policy" "bastion_secrets" {
  count = local.bastion_enabled ? 1 : 0

  name = "${var.name}-bastion-secrets"
  role = aws_iam_role.bastion[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = concat([
          aws_secretsmanager_secret.bastion_private_key[0].arn
          ], local.rds_enabled ? [
          aws_secretsmanager_secret.database_url[0].arn,
          # Also allow access to AWS-managed RDS secret
          local.is_aurora ? aws_rds_cluster.main[0].master_user_secret[0].secret_arn : aws_db_instance.main[0].master_user_secret[0].secret_arn
        ] : [])
      }
    ]
  })
}

# Instance profile for bastion
resource "aws_iam_instance_profile" "bastion" {
  count = local.bastion_enabled ? 1 : 0

  name = "${var.name}-bastion-profile"
  role = aws_iam_role.bastion[0].name

  tags = local.common_tags
}

# Bastion EC2 instances
resource "aws_instance" "bastion" {
  for_each = local.bastion_configs_enabled

  ami                    = data.aws_ami.amazon_linux[0].id
  instance_type          = each.value.instance_type
  key_name               = aws_key_pair.bastion[0].key_name
  vpc_security_group_ids = [aws_security_group.bastion[each.key].id]
  subnet_id              = aws_subnet.public[each.value.index % length(aws_subnet.public)].id
  iam_instance_profile   = aws_iam_instance_profile.bastion[0].name

  associate_public_ip_address = true

  # Start in stopped state by default unless explicitly requested to start
  instance_initiated_shutdown_behavior = "stop"

  user_data_base64 = base64encode(<<-EOF
#!/bin/bash
# Log to a file for debugging, but don't expose sensitive data
exec 1>/var/log/bastion-setup.log 2>&1
echo "Starting bastion setup at $(date)"

    # Update system
    echo "Updating system packages..."
    dnf update -y

    # Create ${each.value.username} user
    echo "Creating ${each.value.username} user..."
    useradd -m -s /bin/bash ${each.value.username}
    usermod -aG wheel ${each.value.username}
    mkdir -p /home/${each.value.username}/.ssh
    cp /home/ec2-user/.ssh/authorized_keys /home/${each.value.username}/.ssh/
%{if each.value.public_key != null~}
    # Add additional public key if provided - ensure it's on a new line
    echo "" >> /home/${each.value.username}/.ssh/authorized_keys
    echo "${each.value.public_key}" >> /home/${each.value.username}/.ssh/authorized_keys
%{endif~}
    chown -R ${each.value.username}:${each.value.username} /home/${each.value.username}/.ssh
    chmod 700 /home/${each.value.username}/.ssh
    chmod 600 /home/${each.value.username}/.ssh/authorized_keys

    # Enable passwordless sudo for bastion user
    echo "${each.value.username} ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/${each.value.username}
    chmod 440 /etc/sudoers.d/${each.value.username}
    echo "User ${each.value.username} created successfully with sudo access"


    # Create .bashrc with automatic PGPASSWORD export for database access
    cat >> /home/${each.value.username}/.bashrc << 'BASHRC'

# PostgreSQL environment from DATABASE_URL
%{if local.rds_enabled~}
if command -v aws >/dev/null 2>&1; then
    # Get the JSON and extract DATABASE_URL using grep and sed (no jq needed)
    SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id ${var.name}-database-url --query SecretString --output text --region ${var.aws_region} 2>/dev/null)
    if [ -n "$SECRET_JSON" ]; then
        # Extract DATABASE_URL using grep and sed
        DATABASE_URL=$(echo "$SECRET_JSON" | grep -o '"DATABASE_URL": "[^"]*"' | sed 's/"DATABASE_URL": "//' | sed 's/"$//')
        
        if [ -n "$DATABASE_URL" ]; then
            # Parse postgres://user:password@host:port/database?params format
            export PGUSER=$(echo "$DATABASE_URL" | sed -n 's|postgres://\([^:]*\):.*|\1|p')
            export PGPASSWORD=$(echo "$DATABASE_URL" | sed -n 's|postgres://[^:]*:\([^@]*\)@.*|\1|p')
            export PGHOST=$(echo "$DATABASE_URL" | sed -n 's|postgres://[^@]*@\([^:]*\):.*|\1|p')
            export PGPORT=$(echo "$DATABASE_URL" | sed -n 's|postgres://[^@]*@[^:]*:\([^/]*\)/.*|\1|p')
            export PGDATABASE=$(echo "$DATABASE_URL" | sed -n 's|postgres://[^/]*/\([^?]*\).*|\1|p')
        fi
    fi
fi
%{endif~}
BASHRC

    chown ${each.value.username}:${each.value.username} /home/${each.value.username}/.bashrc

    # Install AWS CLI v2 for ARM64
    curl "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip"
    unzip awscliv2.zip
    ./aws/install

    # Install psql client for Amazon Linux 2023 (PostgreSQL 17)
    dnf install -y postgresql17

    # Install other useful tools
    dnf install -y htop nano vim git curl wget jq
    
%{if var.efs.enabled && each.value.efs && length(var.efs.mounts) > 0~}
    # Install EFS utilities
    dnf install -y amazon-efs-utils
    
    # Create mount directories and mount all EFS mounts
%{for mount_name, mount_config in var.efs.mounts~}
    mkdir -p /mount/${mount_name}
    echo "${aws_efs_file_system.main[0].id}.efs.${var.aws_region}.amazonaws.com:/ /mount/${mount_name} efs defaults,_netdev,accesspoint=${aws_efs_access_point.mounts[mount_name].id} 0 0" >> /etc/fstab
    mount /mount/${mount_name}
    chown ${each.value.username}:${each.value.username} /mount/${mount_name}
%{endfor~}
%{endif~}

    # Setup systemd service to control instance shutdown behavior
    cat > /etc/systemd/system/bastion-lifecycle.service << 'SERVICE'
[Unit]
Description=Bastion Instance Lifecycle Management
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true

[Install]
WantedBy=multi-user.target
SERVICE

    systemctl enable bastion-lifecycle.service
    systemctl start bastion-lifecycle.service

    # Mark setup as complete
    echo "Bastion setup completed at $(date)"
    touch /var/lib/cloud/instance/bastion-setup-complete

%{if !each.value.start_instance~}
    echo "Scheduling shutdown in 5 minutes as start_instance is false"
    shutdown -h +1 "Bastion instance will shutdown in 1 minute (created in stopped state)"
%{endif~}
  EOF
  )

  tags = merge(local.common_tags, {
    Name = "${var.name}-${each.value.name}"
  })
}

# Route53 records for bastion subdomains (if DNS domain is configured and subdomain is specified)
resource "aws_route53_record" "bastion" {
  for_each = {
    for name, config in local.bastion_configs_enabled :
    name => config
    if var.dns.domain != null && config.subdomain != null
  }

  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = "${each.value.subdomain}.${var.dns.domain}"
  type    = "A"
  ttl     = 300
  records = [aws_instance.bastion[each.key].public_ip]

  depends_on = [aws_instance.bastion]
}

# Output bastion connection details
output "bastion_public_ips" {
  value = {
    for name, config in local.bastion_configs_enabled :
    name => aws_instance.bastion[name].public_ip
  }
  description = "Public IP addresses of all bastion hosts"
}

output "bastion_ssh_commands" {
  value = {
    for name, config in local.bastion_configs_enabled :
    name => (
      config.subdomain != null && var.dns.domain != null ?
      "ssh -i bastion_key ${config.username}@${config.subdomain}.${var.dns.domain}" :
      "ssh -i bastion_key ${config.username}@${aws_instance.bastion[name].public_ip}"
    )
  }
  description = "SSH commands to connect to each bastion host (get private key from Secrets Manager first)"
}

output "bastion_private_key_secret_name" {
  value       = local.bastion_enabled ? aws_secretsmanager_secret.bastion_private_key[0].name : null
  description = "Name of the secret containing the bastion private key (shared across all instances)"
}

output "bastion_key_retrieval_command" {
  value       = local.bastion_enabled ? "aws secretsmanager get-secret-value --secret-id ${aws_secretsmanager_secret.bastion_private_key[0].name} --query SecretString --output text --region ${var.aws_region} | jq -r .private_key > bastion_key && chmod 600 bastion_key" : null
  description = "Command to retrieve and save the bastion private key (works for all bastion instances)"
}

output "bastion_domain_names" {
  value = {
    for name, config in local.bastion_configs_enabled :
    name => (config.subdomain != null && var.dns.domain != null ? "${config.subdomain}.${var.dns.domain}" : null)
  }
  description = "Domain names for each bastion host (if subdomain is configured)"
}

# Database outputs are now in rds.tf
