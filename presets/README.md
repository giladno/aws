# Configuration Presets

This directory contains pre-configured Terraform variable files for common deployment scenarios. These presets provide sensible defaults for different environments and can be used as starting points for your deployments.

## Available Presets

### 1. Development (`development.tfvars`)
**Purpose**: Cost-optimized configuration for development and testing environments.

**Key Features**:
- Single NAT gateway for cost savings
- Minimal RDS configuration (standard PostgreSQL)
- Short log retention periods (7 days)
- Relaxed monitoring thresholds
- No bastion host (use AWS SSM Session Manager)
- Auto-cleanup after 90 days

**Use When**: Local development, feature testing, CI/CD testing environments

### 2. Staging (`staging.tfvars`)
**Purpose**: Production-like configuration for pre-production testing and validation.

**Key Features**:
- High availability networking (multiple NATs)
- Aurora PostgreSQL Serverless
- Moderate log retention (14 days)
- Production-like monitoring thresholds
- Optional bastion with restricted access
- Comprehensive service examples

**Use When**: Integration testing, UAT, performance testing, staging deployments

### 3. Production (`production.tfvars`)
**Purpose**: Full production configuration with high availability, security, and compliance features.

**Key Features**:
- Maximum high availability and fault tolerance
- Aurora PostgreSQL with multi-AZ deployment
- Extended log retention (90 days)
- Strict monitoring and alerting
- Comprehensive security configurations
- Full service scaling and Lambda provisioned concurrency
- Compliance-ready settings

**Use When**: Production deployments, customer-facing applications

## How to Use

1. **Copy the preset file** to your terraform directory:
   ```bash
   cp presets/development.tfvars terraform.tfvars
   ```

2. **Customize the configuration** for your specific needs:
   - Update `name` and `aws_region` variables
   - Modify service configurations
   - Adjust resource sizes and scaling parameters
   - Configure your domain name (if using DNS)

3. **Apply the configuration**:
   ```bash
   terraform plan
   terraform apply
   ```

## Customization Guidelines

### Required Changes
- **name**: Change to your project name
- **aws_region**: Set to your preferred AWS region
- **dns.domain**: Set to your actual domain name (if using)
- **Service images**: Update to your actual container registry URLs

### Optional Customizations
- **VPC CIDR blocks**: Adjust if you have network conflicts
- **Resource sizing**: Scale CPU/memory based on your needs
- **Monitoring settings**: Adjust thresholds based on your SLAs
- **Log retention**: Extend or shorten based on compliance requirements

## Cost Considerations

| Preset | Estimated Monthly Cost* | Primary Cost Drivers |
|--------|------------------------|---------------------|
| Development | $50-150 | Single NAT, t3.micro RDS, minimal scaling |
| Staging | $200-500 | Aurora Serverless, moderate scaling |
| Production | $500-2000+ | Multi-AZ Aurora, provisioned concurrency, high availability |

*Costs are estimates and will vary based on usage, region, and specific configurations.

## Security Notes

### Development
- Bastion disabled by default (use AWS SSM Session Manager)
- Relaxed monitoring for development productivity
- Auto-cleanup policies to prevent cost accumulation

### Staging
- Bastion access restricted to private networks
- Production-like security with some conveniences
- Comprehensive logging for debugging

### Production
- Maximum security configurations
- Restricted network access
- Comprehensive audit logging
- Compliance-ready settings

## Migration Between Environments

When moving from one preset to another:

1. **Plan the migration**: Review differences between configurations
2. **Backup data**: Ensure RDS snapshots and S3 backups are current
3. **Test thoroughly**: Use staging environment to validate changes
4. **Monitor closely**: Watch metrics during and after migration

## Support

For questions about these presets or customization help:
- Review the main `terraform.tfvars.example` for detailed configuration options
- Check `CLAUDE.md` for comprehensive documentation
- Consult AWS documentation for service-specific configurations