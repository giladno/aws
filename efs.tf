# EFS File System
resource "aws_efs_file_system" "main" {
  count = local.efs_config.enabled ? 1 : 0

  creation_token   = "${var.name}-efs"
  performance_mode = var.efs.performance_mode
  throughput_mode  = var.efs.throughput_mode

  provisioned_throughput_in_mibps = var.efs.throughput_mode == "provisioned" ? var.efs.provisioned_throughput_in_mibps : null

  encrypted  = var.efs.kms != false
  kms_key_id = var.efs.kms != false && var.efs.kms != true ? var.efs.kms : null

  tags = merge(local.common_tags, {
    Name = "${var.name}-efs"
  })
}

# EFS Security Group - statically defined, rules added separately
resource "aws_security_group" "efs" {
  count = local.efs_config.enabled ? 1 : 0

  name_prefix = "${var.name}-efs-"
  vpc_id      = aws_vpc.main.id
  description = "Security group for EFS file system access"

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All outbound traffic"
  }

  tags = merge(local.common_tags, {
    Name = "${var.name}-efs-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# EFS ingress rule from bastion
resource "aws_security_group_rule" "efs_from_bastion" {
  count = local.efs_config.needs_bastion_access ? 1 : 0

  type                     = "ingress"
  from_port                = 2049
  to_port                  = 2049
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.bastion[0].id
  security_group_id        = aws_security_group.efs[0].id
  description              = "NFS access from bastion"
}

# EFS ingress rule from Lambda shared security group
resource "aws_security_group_rule" "efs_from_lambda" {
  count = local.efs_config.needs_lambda_access ? 1 : 0

  type                     = "ingress"
  from_port                = 2049
  to_port                  = 2049
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.lambda_shared[0].id
  security_group_id        = aws_security_group.efs[0].id
  description              = "NFS access from Lambda functions"
}

# EFS ingress rules from services that use EFS
resource "aws_security_group_rule" "efs_from_services" {
  for_each = local.services_with_efs

  type                     = "ingress"
  from_port                = 2049
  to_port                  = 2049
  protocol                 = "tcp"
  source_security_group_id = module.services[each.key].security_group_id
  security_group_id        = aws_security_group.efs[0].id
  description              = "NFS access from service ${each.key}"
}

# EFS Mount Targets with proper security group attachment
resource "aws_efs_mount_target" "main" {
  count = local.efs_config.enabled ? length(aws_subnet.private) : 0

  file_system_id  = aws_efs_file_system.main[0].id
  subnet_id       = aws_subnet.private[count.index].id
  security_groups = [aws_security_group.efs[0].id]

  # Mount targets don't support tags directly
}

# EFS Access Points for each mount
resource "aws_efs_access_point" "mounts" {
  for_each = local.efs_mount_points

  file_system_id = aws_efs_file_system.main[0].id

  posix_user {
    gid = each.value.owner_gid
    uid = each.value.owner_uid
  }

  root_directory {
    path = each.value.path
    creation_info {
      owner_gid   = each.value.owner_gid
      owner_uid   = each.value.owner_uid
      permissions = each.value.permissions
    }
  }

  tags = merge(local.common_tags, {
    Name = "${var.name}-efs-${each.key}"
  })
}