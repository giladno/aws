# Docker Build and Push for Services with Source Configuration
# This file handles building container images from source and pushing to ECR

# Docker build and push for services with source configuration
resource "null_resource" "docker_build" {
  for_each = {
    for name, config in local.services_unified_enabled : name => config
    if config.source != null
  }

  # Triggers to rebuild when source files change
  triggers = {
    source_hash     = data.archive_file.service_source[each.key].output_base64sha256
    dockerfile_path = "${each.value.source.dir}/${each.value.source.dockerfile}"
    ecr_repository  = aws_ecr_repository.main[0].repository_url
    build_args      = jsonencode(each.value.source.build_args)
    target          = each.value.source.target != null ? each.value.source.target : ""
    ignore_patterns = jsonencode(each.value.source.ignore)
  }

  # Build and push the Docker image
  provisioner "local-exec" {
    command = <<-EOT
      set -e
      
      # Function to handle errors
      handle_error() {
        local exit_code=$?
        echo "ERROR: Docker build failed for service: ${each.key} with exit code: $exit_code" >&2
        # Clean up any partial artifacts
        rm -f "/tmp/terraform-${each.key}-digest-tag" 2>/dev/null || true
        exit $exit_code
      }
      
      # Set up error handling
      trap 'handle_error' ERR
      
      # Variables
      SERVICE_NAME="${each.key}"
      SOURCE_DIR="${each.value.source.dir}"
      DOCKERFILE="${each.value.source.dockerfile}"
      CONTEXT="${each.value.source.context}"
      TARGET="${each.value.source.target != null ? each.value.source.target : ""}"
      ECR_REPOSITORY="${aws_ecr_repository.main[0].repository_url}"
      AWS_REGION="${var.aws_region}"
      BUILD_ARGS="${join(" ", [for k, v in each.value.source.build_args : "--build-arg ${k}=${v}"])}"
      
      echo "Building Docker image for service: $SERVICE_NAME"
      echo "Source directory: $SOURCE_DIR"
      echo "Dockerfile: $DOCKERFILE"
      echo "Context: $CONTEXT"
      echo "ECR Repository: $ECR_REPOSITORY"
      
      # Check if source directory exists
      if [ ! -d "$SOURCE_DIR" ]; then
        echo "Error: Source directory '$SOURCE_DIR' does not exist"
        exit 1
      fi
      
      # Check if Dockerfile exists
      if [ ! -f "$SOURCE_DIR/$DOCKERFILE" ]; then
        echo "Error: Dockerfile '$SOURCE_DIR/$DOCKERFILE' does not exist"
        exit 1
      fi
      
      # Get ECR login token
      echo "Logging into ECR..."
      aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_REPOSITORY
      
      # Build the image
      echo "Building Docker image..."
      BUILD_CONTEXT="$SOURCE_DIR/$CONTEXT"
      DOCKERFILE_PATH="$SOURCE_DIR/$DOCKERFILE"
      
      # Build command
      DOCKER_BUILD_CMD="docker build"
      DOCKER_BUILD_CMD="$DOCKER_BUILD_CMD -f $DOCKERFILE_PATH"
      DOCKER_BUILD_CMD="$DOCKER_BUILD_CMD $BUILD_ARGS"
      
      if [ -n "$TARGET" ]; then
        DOCKER_BUILD_CMD="$DOCKER_BUILD_CMD --target $TARGET"
      fi
      
      DOCKER_BUILD_CMD="$DOCKER_BUILD_CMD -t $ECR_REPOSITORY:$SERVICE_NAME-temp"
      DOCKER_BUILD_CMD="$DOCKER_BUILD_CMD $BUILD_CONTEXT"
      
      echo "Executing: $DOCKER_BUILD_CMD"
      eval $DOCKER_BUILD_CMD
      
      # Get the image ID and create digest-based tag
      IMAGE_ID=$(docker inspect --format='{{.Id}}' $ECR_REPOSITORY:$SERVICE_NAME-temp | cut -d':' -f2 | cut -c1-12)
      DIGEST_TAG="$SERVICE_NAME-$IMAGE_ID"
      
      # Tag with digest-based tag
      echo "Creating digest-based tag: $DIGEST_TAG"
      docker tag $ECR_REPOSITORY:$SERVICE_NAME-temp $ECR_REPOSITORY:$DIGEST_TAG
      
      # Push the digest-based image
      echo "Pushing Docker image to ECR..."
      docker push $ECR_REPOSITORY:$DIGEST_TAG
      
      # Clean up temporary tag
      echo "Cleaning up temporary tag..."
      docker rmi $ECR_REPOSITORY:$SERVICE_NAME-temp || true
      
      # Write the digest tag to a file for Terraform to read
      echo "$DIGEST_TAG" > "/tmp/terraform-$SERVICE_NAME-digest-tag"
      
      echo "Successfully built and pushed Docker image for service: $SERVICE_NAME"
      echo "Digest tag: $DIGEST_TAG"
    EOT
  }

  # Cleanup local images after push
  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      ECR_REPOSITORY="${self.triggers.ecr_repository}"
      if [ -n "$ECR_REPOSITORY" ]; then
        echo "Cleaning up local Docker images for $ECR_REPOSITORY"
        docker rmi $ECR_REPOSITORY:latest 2>/dev/null || true
        # Remove timestamped images (best effort)
        docker images $ECR_REPOSITORY --format "table {{.Repository}}:{{.Tag}}" | grep -v "TAG" | xargs -r docker rmi 2>/dev/null || true
      fi
    EOT
  }

  depends_on = [
    aws_ecr_repository.main,
    data.archive_file.service_source,
    null_resource.tmp_directory
  ]
}

# Archive data source to track source file changes
data "archive_file" "service_source" {
  for_each = {
    for name, config in local.services_unified_enabled : name => config
    if config.source != null
  }

  type        = "zip"
  source_dir  = each.value.source.dir
  output_path = "${var.tmp}/terraform-${var.name}-${each.key}-source.zip"

  # Exclude files based on ignore patterns (defaults to common patterns, user can override)
  excludes = each.value.source.ignore

  depends_on = [null_resource.tmp_directory]
}

# Note: No longer using "latest" tag - services use digest-based tags only

# Data source to read the digest tag from the build process
data "external" "service_digest_tag" {
  for_each = {
    for name, config in local.services_unified_enabled : name => config
    if config.source != null
  }

  program = ["sh", "-c", "if [ -f /tmp/terraform-${each.key}-digest-tag ]; then echo \"{\\\"digest_tag\\\": \\\"$(cat /tmp/terraform-${each.key}-digest-tag)\\\"}\"; else echo 'Error: Docker build not completed for ${each.key}' >&2; exit 1; fi"]

  depends_on = [null_resource.docker_build]
}

# Local values for service images
locals {
  # Create a map of service images (either from ECR builds or provided images)
  service_images = {
    for name, config in local.services_unified_enabled : name =>
    config.source != null ?
    "${aws_ecr_repository.main[0].repository_url}:${data.external.service_digest_tag[name].result.digest_tag}" :
    config.image
  }
}