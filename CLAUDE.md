# CLAUDE.md

Production-ready AWS Terraform module with enterprise security controls.

## Quick Start
```hcl
module "aws_infrastructure" {
  source = "./path-to-this-module"
  name       = "my-app"      # Required
  aws_region = "us-west-2"   # Required
}
```

## Architecture
- **VPC**: Multi-AZ subnets, NAT gateways, VPC endpoints
- **ECS Fargate**: Container orchestration + ALB
- **RDS**: Aurora PostgreSQL Serverless v2
- **Lambda**: Auto Node.js dependency layers
- **S3/CloudFront**: Storage + CDN with SSL
- **SES**: Email service
- **Monitoring**: CloudWatch dashboards

Security: Network isolation, IAM least privilege, encryption by default.

## Commands
```bash
npm run tf:init    # Initialize
npm run tf:plan    # Plan changes
npm run tf:apply   # Apply changes
```

## Encryption
`kms` property: `true` (AWS-managed), `false` (none), `"AES256"` (S3), or KMS ARN.

## Services
```hcl
services = {
  api = {
    # Image or source code build
    image = "my-registry/api:latest"
    source = { dir = "./src/api" }  # Auto-build option
    
    # HTTP exposure (optional)
    http = {
      port = 3000
      subdomain = "api"  # or path_pattern = "/api/*"
    }
    
    # Database environment variable
    environment = {
      database = true                           # DATABASE_URL from default secret
      # database = "DB_CONNECTION"              # Custom env var name
      # database = {                            # Full control
      #   name = "DATABASE_URL"                 # Env var name (defaults to "DATABASE_URL")
      #   secret = "my-db-secret:database_url"  # Secret:key (colon for JSON)
      # }
      # database = { secret = "my-secret:key" } # Just custom secret, name defaults to "DATABASE_URL"
    }
    
    # Network access (default: blocked)
    network_access = [
      { protocol = "tcp", ports = [443], cidrs = ["0.0.0.0/0"] }
    ]
    
    # Volumes (optional)
    volumes = {
      temp-data = null              # Non-persistent
      host-logs = "/var/log"        # Host path
    }
    
    # Multi-container (optional)
    containers = {
      nginx = { image = "nginx:alpine", essential = false }
    }
  }
}
```

## Lambda
```hcl
lambda = {
  # Global defaults
  runtime = "nodejs22.x"
  timeout = 60
  memory_size = 256
  
  # Global environment/permissions
  environment = { s3 = true }
  permissions = { s3 = true, ses = true }
  
  functions = {
    api = {
      source_dir = "./functions/api"
      environment = { 
        database = true                         # DATABASE_URL from default secret
        # database = "DB_URL"                   # Custom env var name
        # database = {                          # Full control
        #   name = "DATABASE_URL"               # Env var name (defaults to "DATABASE_URL")
        #   secret = "my-secret:db_connection"  # Secret:key for JSON secrets
        # }
        # database = { secret = "my-secret:key" } # Just custom secret, name defaults to "DATABASE_URL"
      }
      
      # Triggers
      triggers = {
        http = { subdomain = "api" }
        sqs = { batch_size = 5 }
        s3 = { events = ["s3:ObjectCreated:*"] }
        schedule = { schedule_expression = "rate(1 hour)" }
      }
    }
  }
}
```

## Database
```hcl
# Aurora PostgreSQL Serverless v2 (recommended)
rds = {
  enabled = true
  engine_type = "aurora-postgresql"
  aurora_config = {
    serverless_enabled = true
    serverless_min_capacity = 0.5
    serverless_max_capacity = 4
  }
}
```

## S3/CloudFront
```hcl
s3 = {
  enabled = true
  public = "/public"  # Static files
  spa = "index.html"  # SPA support
}
```

## DNS/SSL
Set `dns.domain = "example.com"` to enable Route53 and dual SSL certificates.

## Bastion
```bash
# Connect
aws secretsmanager get-secret-value --secret-id my-app-bastion-private-key --query SecretString --output text --region us-west-2 | jq -r .private_key > key && chmod 600 key
ssh bastion@bastion.domain.com -i key
```

## Examples

**Minimal:**
```hcl
module "aws_infrastructure" {
  source = "./path-to-this-module"
  name = "my-app-dev"
  aws_region = "us-west-2"
  rds = { enabled = false }
}
```

**Production:**
```hcl
module "aws_infrastructure" {
  source = "./path-to-this-module"
  name = "my-app"
  aws_region = "us-west-2"
  dns = { domain = "example.com" }
  
  services = {
    api = {
      source = { dir = "./src/api" }
      http = { port = 3000, subdomain = "api" }
      environment = { database = true }
    }
  }
  
  rds = { enabled = true }
  monitoring = { enabled = true }
}
```