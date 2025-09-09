# AWS Infrastructure Terraform Module

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Terraform](https://img.shields.io/badge/Terraform-%E2%89%A5%201.0-623CE4)](https://www.terraform.io/)
[![AWS](https://img.shields.io/badge/AWS-Production%20Ready-232F3E)](https://aws.amazon.com/)

A **production-ready, security-first** Terraform module for AWS infrastructure. Deploy enterprise-grade environments with VPC, ECS Fargate, RDS Aurora, Lambda functions, and comprehensive security controls.

## 🚀 Features

### 🏗️ **Infrastructure Components**
- **VPC** - Multi-AZ setup with public, private, and database subnets
- **ECS Fargate** - Container orchestration with Application Load Balancer
- **RDS PostgreSQL** - Aurora Serverless v2 or standard PostgreSQL with optional RDS Proxy
- **Lambda Functions** - Serverless compute with automatic Node.js dependency layers and multiple triggers
- **S3** - Object storage with lifecycle policies, static hosting, and CloudFront integration
- **CloudFront** - Global CDN with dual SSL certificate management
- **DNS & SSL** - Route53 hosted zones with automatic certificate provisioning
- **SES** - Simple Email Service with domain verification and DKIM authentication
- **Bastion Host** - Secure EC2 access to private resources with ARM-based instances
- **Monitoring** - CloudWatch dashboards with individual widgets per service/Lambda

### 🔒 **Security-First Design**
- **Default Deny Network Access** - Services and Lambda functions blocked from internet by default
- **Granular Outbound Controls** - Explicit rules required for external access
- **IAM Least Privilege** - Per-service and per-Lambda roles with minimal permissions
- **AWS-Managed Secrets** - RDS passwords managed by AWS (not in Terraform state)
- **Network Isolation** - Database subnets completely isolated from internet
- **VPC Endpoints** - Secure communication with AWS services (auto-enabled based on usage)
- **Encryption Everywhere** - All data encrypted at rest and in transit

## 📋 Table of Contents

- [Quick Start](#-quick-start)
- [Configuration](#-configuration)
- [Services Configuration](#-services-configuration)
- [Lambda Functions](#-lambda-functions)
- [Database Configuration](#-database-configuration)
- [S3 & CloudFront](#-s3--cloudfront)
- [DNS & SSL](#-dns--ssl)
- [SES Email Service](#-ses-email-service)
- [Security Features](#-security-features)
- [Monitoring](#-monitoring)
- [Examples](#-examples)
- [Contributing](#-contributing)

## 🚀 Quick Start

### Prerequisites

- [Terraform](https://www.terraform.io/downloads.html) >= 1.0
- [AWS CLI](https://aws.amazon.com/cli/) configured with appropriate credentials
- Node.js (optional, for npm scripts)

### 🔍 Checking Resource Availability

Before deploying, verify that required resources are available in your target region:

```bash
# Check available database engine versions
aws rds describe-db-engine-versions --engine aurora-postgresql --region your-region
aws rds describe-db-engine-versions --engine postgres --region your-region

# Verify instance type availability
aws ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values=t4g.micro --region your-region

# Check Aurora Serverless v2 support
aws rds describe-orderable-db-instance-options --engine aurora-postgresql --query 'OrderableDBInstanceOptions[?contains(SupportedEngineModes || `[]`, `serverless`)].EngineVersion' --region your-region

# List available AZs
aws ec2 describe-availability-zones --region your-region --query 'AvailabilityZones[].ZoneName' --output table

# Check Lambda account settings and limits
aws lambda get-account-settings --region your-region
```

### 1. Basic Setup

```hcl
module "aws_infrastructure" {
  source = "github.com/giladno/aws"
  
  # Required variables
  name       = "my-app"
  aws_region = "us-west-2"
  
  # Optional: Override environment
  environment = "production"
}
```

### 2. Initialize and Deploy

```bash
# Using npm scripts (recommended)
npm run tf:init
npm run tf:plan
npm run tf:apply

# Or direct Terraform commands
terraform init
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
```

### 3. Create terraform.tfvars

```hcl
name       = "my-app"
aws_region = "us-west-2"
environment = "production"

# Optional: Add custom tags
tags = {
  Team = "platform"
  Cost = "shared"
}
```

## ⚙️ Configuration

### Core Variables

| Variable | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `name` | `string` | ✅ | - | Project name (used as prefix for all resources) |
| `aws_region` | `string` | ✅ | - | AWS region for resources |
| `environment` | `string` | ❌ | `"production"` | Environment name |
| `tags` | `map(string)` | ❌ | `{}` | Additional tags for all resources |

### DNS Configuration

```hcl
dns = {
  domain       = "example.com"  # Enable Route53 and SSL
  www_redirect = true           # Auto-detects based on ALB usage
  alb          = false          # Force ALB creation for DNS redirects
}
```

**Features:**
- Automatic SSL certificate provisioning via [AWS Certificate Manager](https://aws.amazon.com/certificate-manager/)
- Dual certificate management (regional + CloudFront in us-east-1)
- Smart www redirect (ALB-based when possible, S3+CloudFront fallback)
- Subdomain routing for services and Lambda functions

## 🐳 Services Configuration

Deploy containerized applications with **secure defaults**:

```hcl
services = {
  # Secure service (no outbound internet access)
  api = {
    image          = "your-registry/api:latest"
    container_port = 3000
    desired_count  = 2
    
    # Environment variables
    environment = {
      region   = true  # Sets AWS_REGION
      database = true  # Sets DATABASE_URL (if RDS enabled)
      s3       = true  # Sets S3_BUCKET (if S3 enabled)
    }
    
    # Network access (defaults to blocked)
    network_access = {
      outbound = [
        { protocol = "tcp", ports = [443], cidrs = ["0.0.0.0/0"] }  # HTTPS only
      ]
    }
    
    # CORS configuration for APIs
    cors = {
      enabled       = true
      allow_origins = ["https://myapp.com"]
      allow_methods = ["GET", "POST", "PUT", "DELETE"]
      allow_headers = ["Content-Type", "Authorization"]
    }
  }
  
  # Legacy service with full internet access
  legacy = {
    image = "legacy-app:latest"
    network_access = {
      outbound = true  # Explicit opt-in required
    }
  }
}
```

### Service Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `image` | `string` | **required** | Container image URI |
| `container_port` | `number` | `3000` | Port exposed by container |
| `task_cpu` | `number` | `256` | [CPU units](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task_definition_parameters.html#task_size) (256, 512, 1024, 2048, 4096) |
| `task_memory` | `number` | `512` | Memory in MB ([valid combinations](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task_definition_parameters.html#task_size)) |
| `desired_count` | `number` | `1` | Number of running tasks |
| `health_check_path` | `string` | `"/"` | ALB health check endpoint |
| `subdomain` | `string` | `null` | Custom subdomain (e.g., "api" for api.domain.com) |
| `path_pattern` | `string` | `"/*"` | ALB path pattern for routing |

### Network Access Control

**🔒 Secure by Default**: All services start with **no outbound internet access**.

```hcl
network_access = {
  outbound = null    # Default: Block all outbound traffic
  outbound = true    # Explicit: Allow all outbound traffic  
  outbound = [       # Granular: Specific rules only
    { protocol = "tcp", ports = [443], cidrs = ["0.0.0.0/0"] },
    { protocol = "tcp", ports = [5432], cidrs = ["10.0.0.0/16"] }
  ]
}
```

## ⚡ Lambda Functions

**NEW**: Serverless functions with automatic dependency management and the same security controls as ECS services:

```hcl
lambda = {
  # HTTP API Gateway function
  webhook = {
    source_dir = "./functions/webhook"  # Must contain package.json for Node.js
    runtime    = "nodejs22.x"
    timeout    = 30
    
    # Automatic Node.js dependency layer creation
    # - Detects Node.js runtime automatically
    # - Creates optimized layer with Docker builds
    # - Excludes node_modules from function ZIP
    # - Rebuilds only when package-lock.json changes
    
    # VPC configuration (optional)
    vpc_config = {
      subnet_ids = []  # Private subnets auto-assigned
    }
    
    # Same network controls as services
    network_access = {
      outbound = [
        { protocol = "tcp", ports = [443], cidrs = ["0.0.0.0/0"] }
      ]
    }
    
    # HTTP API Gateway trigger
    triggers = {
      http = {
        enabled      = true
        methods      = ["POST"]
        subdomain    = "webhook"  # webhook.domain.com
        cors = {
          allow_origins = ["https://github.com", "https://gitlab.com"]
          allow_methods = ["POST"]
        }
      }
    }
  }
  
  # SQS queue processor
  queue_processor = {
    source_dir = "./functions/queue"
    runtime    = "nodejs22.x"
    
    triggers = {
      sqs = {
        enabled         = true
        batch_size      = 5
        queue_config = {
          visibility_timeout_seconds = 180
          max_receive_count         = 3
          enable_dlq                = true  # Auto-creates dead letter queue
        }
      }
    }
  }
  
  # S3 object processor
  image_processor = {
    source_dir  = "./functions/images"
    runtime     = "nodejs22.x"
    memory_size = 1024
    timeout     = 300
    
    triggers = {
      s3 = {
        enabled       = true
        events        = ["s3:ObjectCreated:*"]
        filter_prefix = "uploads/images/"
        filter_suffix = ".jpg"
      }
    }
  }
  
  # Scheduled function
  cleanup_task = {
    source_dir = "./functions/cleanup"
    runtime    = "nodejs22.x"
    
    triggers = {
      schedule = {
        enabled             = true
        schedule_expression = "rate(1 hour)"
        description         = "Cleanup old data hourly"
      }
    }
  }
}
```

### Lambda Trigger Types

| Trigger | Description | Configuration |
|---------|-------------|---------------|
| **HTTP** | API Gateway integration | `methods`, `path_pattern`, `subdomain`, `cors` |
| **Schedule** | CloudWatch Events | `schedule_expression` (cron/rate) |
| **SQS** | Queue processing | Auto-creates queue and DLQ |
| **S3** | Object events | `events`, `filter_prefix`, `filter_suffix` |

### Automatic Node.js Dependency Layers

**NEW**: The module automatically optimizes Node.js Lambda deployments:

- **Auto-detection**: Detects Node.js runtimes (`nodejs18.x`, `nodejs20.x`, `nodejs22.x`)
- **Docker builds**: Uses official AWS Lambda images for platform compatibility
- **Smart caching**: Only rebuilds when `package-lock.json` changes
- **Optimized deployment**: Function ZIP excludes `node_modules`, relies on layer
- **Proper structure**: Creates layers with `/opt/nodejs/node_modules` structure

## 🗄️ Database Configuration

### Aurora PostgreSQL (Recommended)

```hcl
rds = {
  enabled        = true
  engine_type    = "aurora-postgresql"
  engine_version = "17.5"  # Latest supported version
  
  aurora_config = {
    serverless_enabled      = true
    serverless_min_capacity = 0.5   # Scales down to 0.5 ACU
    serverless_max_capacity = 4     # Scales up to 4 ACU
    instance_count          = 2     # For HA
  }
  
  # Security features
  iam_database_authentication = true   # Passwordless access for services/Lambda
  proxy                      = true   # Enable RDS Proxy
  deletion_protection        = true   # Prevent accidental deletion
}
```

### Standard PostgreSQL

```hcl
rds = {
  enabled        = true
  engine_type    = "postgres"
  engine_version = "17.5"  # Latest supported version
  
  postgres_config = {
    instance_class    = "db.t4g.micro"  # ARM-based instances
    allocated_storage = 20
    multi_az         = true             # Enable for production HA
  }
}
```

**Key Features:**
- **AWS-Managed Passwords**: Passwords managed by AWS, not stored in Terraform state
- **IAM Authentication**: Passwordless database access for Aurora (services/Lambda with `environment.database = true`)
- **Automatic Backups**: Configurable retention periods
- **Encryption**: All data encrypted at rest by default

> 📖 **Reference**: [AWS RDS Instance Types](https://aws.amazon.com/rds/instance-types/) | [Aurora Serverless v2](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-serverless-v2.html)

## 🪣 S3 & CloudFront

### S3 Configuration

```hcl
s3 = {
  enabled     = true
  bucket_name = null                    # Defaults to "${name}-s3-bucket"
  versioning  = false                   # Enable for production
  
  # Static website hosting with CloudFront
  public              = "/public"       # Path prefix for static files
  spa                 = "index.html"    # SPA redirect target
  default_root_object = "index.html"    # CloudFront default object
  
  # Lifecycle management
  lifecycle_rules = {
    transition_to_ia_days      = 30     # Move to Infrequent Access (minimum 30 days)
    transition_to_glacier_days = 90     # Move to Glacier
    expiration_days           = null    # Optional deletion after X days
  }
}
```

### Static Website Hosting

The S3 bucket can serve static content via CloudFront:

- **`public` folder**: Files accessible via CloudFront (e.g., `/public/style.css`)
- **SPA support**: 404s redirect to your SPA entry point
- **Custom domains**: Automatic SSL and DNS integration
- **Lifecycle policies**: Automatic cost optimization

### CloudFront Features

- **Origin Access Control (OAC)**: Secure S3 access
- **Global CDN**: Edge locations worldwide
- **Dual SSL**: Regional + CloudFront certificates automatically managed
- **Compression**: Automatic gzip compression
- **Caching**: Configurable TTL policies

> 📖 **Reference**: [AWS S3 Website Hosting](https://docs.aws.amazon.com/AmazonS3/latest/userguide/WebsiteHosting.html) | [CloudFront Origins](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/DownloadDistS3AndCustomOrigins.html)

## 🌐 DNS & SSL

### Automatic SSL Certificates

```hcl
dns = {
  domain = "example.com"  # Automatically provisions SSL certificates
}
```

**Dual Certificate Management:**
- **Regional Certificate**: Created in your specified region for ALB/API Gateway
- **CloudFront Certificate**: Automatically created in `us-east-1` when CloudFront is used
- **Smart Logic**: If your region is already `us-east-1`, only creates one certificate
- **Auto-validation**: Both certificates validated via Route53 DNS records

### WWW Redirects

The module intelligently handles www redirects:

- **With ALB**: Uses cost-efficient ALB listener rules
- **Without ALB**: Creates S3 bucket + CloudFront distribution
- **Auto-detection**: Enabled automatically for top-level domains when ALB exists

### Force ALB Creation

```hcl
dns = {
  domain = "example.com"
  alb    = true  # Force ALB creation for DNS-only redirects
}
```

## 📧 SES Email Service

**NEW**: Configure Simple Email Service for domain-based email sending:

```hcl
ses = {
  enabled = true  # Requires dns.domain to be set
  
  domain_verification = {
    create_verification_record = true   # Auto-create Route53 records
    create_dkim_records       = true   # Enable DKIM authentication
  }
  
  sending_config = {
    reputation_tracking_enabled = true
    delivery_options           = "TLS"  # Secure email transmission
  }
  
  # Optional: Configuration set for advanced tracking
  configuration_set = {
    enabled         = false
    open_tracking   = false  # Requires HTML emails
    click_tracking  = false
  }
  
  # Verified email addresses for testing
  verified_emails = ["noreply@example.com", "support@example.com"]
}
```

### SES Features

- **Domain Verification**: Automatic Route53 record creation
- **DKIM Authentication**: Improves email deliverability
- **Bounce/Complaint Handling**: SNS topic integration
- **Reputation Tracking**: Monitor sending reputation
- **TLS Encryption**: Secure email transmission

**Services Integration**: Services and Lambda functions with `permissions.ses = true` automatically get SES sending permissions.

> 📖 **Reference**: [AWS SES Domain Verification](https://docs.aws.amazon.com/ses/latest/dg/verify-domains.html) | [Terraform aws_ses_domain_identity](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ses_domain_identity)

## 🔒 Security Features

### Network Security

- **🚫 Default Deny**: All services and Lambda functions start with no outbound internet access
- **🎯 Granular Controls**: Explicit rules required for external communication
- **🏠 Private Subnets**: All compute runs in private subnets
- **🗄️ Database Isolation**: Database subnets have no internet access
- **🔗 VPC Endpoints**: Secure AWS service communication (auto-enabled based on usage)

### Access Control

- **👤 IAM Least Privilege**: Per-service and per-Lambda roles with minimal permissions
- **🔐 Secrets Management**: AWS-managed passwords and per-service secret access
- **🚪 Bastion Security**: SSH access requires explicit CIDR configuration

### Bastion Host Configuration

```hcl
vpc = {
  bastion = {
    enabled             = true
    username            = "bastion"
    instance_type       = "t4g.micro"              # ARM-based for cost efficiency
    allowed_cidr_blocks = ["203.0.113.0/24"]       # REQUIRED: Your IP range
    subdomain           = "bastion"                 # Creates bastion.domain.com
    start_instance      = false                     # Start in stopped state
  }
}
```

**Bastion Features:**
- **ARM64 Architecture**: Uses Amazon Linux 2023 ARM64 AMIs for cost efficiency
- **SSH Key Management**: Keys stored securely in AWS Secrets Manager
- **Database Access**: Pre-configured scripts for RDS/Aurora connectivity
- **Subdomain Support**: Optional Route53 integration

**Access Commands:**
```bash
# Retrieve SSH key from Secrets Manager
aws secretsmanager get-secret-value --secret-id my-app-bastion-private-key --query SecretString --output text --region us-west-2 | jq -r .private_key > bastion_key && chmod 600 bastion_key

# Connect to bastion
ssh bastion@bastion.domain.com -i bastion_key
```

> ⚠️ **Security Note**: `allowed_cidr_blocks` is **required** when bastion is enabled. While the module allows `0.0.0.0/0` for flexibility, it will display a security warning.

### VPC Endpoints

Automatically configured based on service usage to reduce internet traffic and costs:

- **ECR API/DKR**: Auto-enabled when Fargate services exist
- **CloudWatch Logs**: Auto-enabled for services, Lambda functions, and RDS
- **Secrets Manager**: Auto-enabled for services with secrets or RDS
- **S3 Gateway**: Auto-enabled when S3 bucket is created (free)

Add custom endpoints:

```hcl
vpc = {
  endpoints = {
    enabled = true
    endpoints = {
      dynamodb = {
        service_name      = "com.amazonaws.us-west-2.dynamodb"
        vpc_endpoint_type = "Gateway"  # Free gateway endpoint
      }
      ssm = {
        service_name        = "com.amazonaws.us-west-2.ssm"
        vpc_endpoint_type   = "Interface"  # Paid interface endpoint
        private_dns_enabled = true
      }
    }
  }
}
```

## 📊 Monitoring

**UPDATED**: Built-in monitoring with enhanced CloudWatch dashboard:

### Dashboard Features

- **Instructions Widget**: Shows how to filter logs and available services/Lambda functions
- **Combined Log Widgets**: All application logs and error logs combined
- **Individual Widgets**: Separate log widget for each service and Lambda function
- **Metric Widgets**: Performance metrics for ALB, RDS, ECS, and CloudFront
- **Pre-built Queries**: CloudWatch Logs Insights queries for common use cases

### Configuration

```hcl
monitoring = {
  enabled = true
  
  sns_notifications = {
    critical_alerts_email = ["ops@example.com", "oncall@example.com"]
    warning_alerts_email  = "monitoring@example.com"
  }
  
  dashboard = {
    enabled = true  # Creates comprehensive dashboard
  }
  
  alarms = {
    # ECS Service thresholds
    ecs_cpu_threshold    = 80   # CPU utilization threshold (%)
    ecs_memory_threshold = 80   # Memory utilization threshold (%)
    
    # Lambda function thresholds
    lambda_error_threshold    = 5     # Error count per 5 minutes
    lambda_duration_threshold = 10000 # Duration in milliseconds
    
    # RDS/Aurora thresholds
    aurora_cpu_threshold         = 80   # CPU utilization threshold (%)
    aurora_connections_threshold = 200  # Database connections threshold
    
    # ALB thresholds
    alb_response_time_threshold = 2   # Response time in seconds
    alb_5xx_error_threshold    = 10  # 5xx error count threshold
  }
  
  # Log monitoring for error detection
  log_monitoring = {
    enabled = true
    error_threshold = 10  # Error count threshold per 5 minutes
    error_patterns = ["ERROR", "FATAL", "Exception", "error:", "failed", "timeout"]
  }
}
```

### Using the Dashboard

1. **Click on any log widget** to open CloudWatch Logs Insights
2. **Add filters to queries**: `| filter component = "hello"` (for specific Lambda/service)
3. **Use individual widgets** to see logs from specific services or Lambda functions
4. **Instructions widget** at the top shows available components and filtering examples

## 📚 Examples

### Minimal Development Setup

```hcl
module "aws_infrastructure" {
  source = "github.com/giladno/aws"
  
  name       = "my-app-dev"
  aws_region = "us-west-2"
  environment = "development"
  
  # Disable optional services for cost savings
  rds = { enabled = false }
  s3  = { enabled = false }
  ses = { enabled = false }
  
  vpc = {
    nat_gateway = {
      single_nat_gateway = true  # Single NAT for cost savings
    }
    bastion = { enabled = false }
  }
  
  # No services = minimal infrastructure
  services = {}
  lambda = {}
}
```

### Production Setup with Full Stack

```hcl
module "aws_infrastructure" {
  source = "github.com/giladno/aws"
  
  name       = "my-app"
  aws_region = "us-west-2"
  environment = "production"
  
  # DNS and SSL
  dns = {
    domain = "example.com"
  }
  
  # Aurora PostgreSQL with HA
  rds = {
    enabled = true
    engine_type = "aurora-postgresql"
    aurora_config = {
      serverless_enabled = true
      serverless_min_capacity = 0.5
      serverless_max_capacity = 8
      instance_count = 2  # For HA
    }
    backup_retention_period = 30
    deletion_protection = true
    proxy = true
  }
  
  # S3 with CloudFront
  s3 = {
    enabled = true
    versioning = true
    public = "/public"
    spa = "index.html"
  }
  
  # Email service
  ses = {
    enabled = true
    domain_verification = {
      create_verification_record = true
      create_dkim_records = true
    }
  }
  
  # VPC with security features
  vpc = {
    flow_logs = {
      enabled = true
      traffic_type = "ALL"
    }
    bastion = {
      enabled = true
      username = "admin"
      allowed_cidr_blocks = ["203.0.113.0/24"]
    }
  }
  
  # Containerized services
  services = {
    api = {
      image = "your-registry/api:latest"
      desired_count = 3
      subdomain = "api"
      environment = {
        database = true
        s3 = true
      }
      network_access = {
        outbound = [
          { protocol = "tcp", ports = [443], cidrs = ["0.0.0.0/0"] }
        ]
      }
      cors = {
        enabled = true
        allow_origins = ["https://example.com"]
      }
    }
    
    admin = {
      image = "your-registry/admin:latest"
      subdomain = "admin"
      environment = {
        database = true
      }
      permissions = {
        ses = true  # Admin can send emails
      }
    }
  }
  
  # Lambda functions
  lambda = {
    webhook = {
      source_dir = "./functions/webhook"
      runtime = "nodejs22.x"
      triggers = {
        http = {
          enabled = true
          methods = ["POST"]
          subdomain = "webhook"
        }
      }
    }
    
    data_processor = {
      source_dir = "./functions/processor"
      runtime = "nodejs22.x"
      memory_size = 512
      triggers = {
        schedule = {
          enabled = true
          schedule_expression = "rate(1 hour)"
        }
      }
      environment = {
        database = true
        s3 = true
      }
    }
  }
  
  # Comprehensive monitoring
  monitoring = {
    enabled = true
    sns_notifications = {
      critical_alerts_email = ["alerts@example.com"]
    }
    dashboard = {
      enabled = true
    }
  }
}
```

### Lambda-Only Serverless Setup

```hcl
module "aws_infrastructure" {
  source = "github.com/giladno/aws"
  
  name       = "serverless-app"
  aws_region = "us-west-2"
  
  dns = {
    domain = "api.example.com"
  }
  
  rds = {
    enabled = true
    engine_type = "aurora-postgresql"
    aurora_config = {
      serverless_enabled = true
      serverless_min_capacity = 0.5
      serverless_max_capacity = 2
    }
  }
  
  s3 = {
    enabled = true
    public = "/public"
    spa = true
  }
  
  # No ECS services - Lambda only
  services = {}
  
  lambda = {
    api = {
      source_dir = "./functions/api"
      runtime = "nodejs22.x"
      triggers = {
        http = {
          enabled = true
          methods = ["GET", "POST", "PUT", "DELETE"]
          path_pattern = "/api"
        }
      }
      environment = {
        database = true
        s3 = true
      }
    }
    
    auth = {
      source_dir = "./functions/auth"
      runtime = "nodejs22.x"
      triggers = {
        http = {
          enabled = true
          methods = ["POST"]
          path_pattern = "/auth"
        }
      }
      environment = {
        database = true
      }
    }
  }
}
```

## ⚠️ AI-Assisted Development Notice

This project was developed with assistance from Claude AI. While efforts have been made to ensure accuracy and quality, **documentation and code may contain errors or inconsistencies**. Please:

- **Test thoroughly** in non-production environments first
- **Review all configurations** before applying to production
- **Validate resource availability** in your target AWS region
- **Report any issues** you encounter

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/amazing-feature`
3. Make your changes and test thoroughly
4. Run the linting and validation: `npm run precommit`
5. Commit your changes: `git commit -m 'Add amazing feature'`
6. Push to the branch: `git push origin feature/amazing-feature`
7. Open a Pull Request

### Development Commands

```bash
# Format and validate
npm run precommit

# Security scan
npm run tf:security

# Generate documentation
npm run tf:docs

# Environment-specific testing
npm run dev:plan
npm run prod:plan
```

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

**Made with ❤️ for the AWS community**

> 🚀 **Quick Deploy**: `terraform apply -var name=my-app -var aws_region=us-west-2`

> 📖 **Documentation**: See [CLAUDE.md](CLAUDE.md) for detailed configuration guide

> 🐛 **Issues**: [GitHub Issues](https://github.com/giladno/aws/issues)