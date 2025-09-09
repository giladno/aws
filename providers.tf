# Ensure temporary directory exists for build artifacts
resource "null_resource" "tmp_directory" {
  provisioner "local-exec" {
    command = <<-EOT
      echo "Creating temporary directory: ${var.tmp}"
      mkdir -p "${var.tmp}"
      echo "Temporary directory ready: ${var.tmp}"
    EOT
  }

  # Run when tmp directory path changes
  triggers = {
    tmp_path = var.tmp
  }
}

# Provider for us-east-1 (required for CloudFront certificates)
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}