# Shared environment variables module
variable "service_name" {
  description = "Name of the service or lambda function"
  type        = string
}

variable "service_type" {
  description = "Type of service: 'service' or 'lambda'"
  type        = string
  default     = "service"
}

variable "environment_config" {
  description = "Environment configuration (database removed - handled at global level)"
  type = object({
    region    = optional(any, null)  # bool or string - only used for services, ignored for Lambda
    node      = optional(any, null)  # bool or string - auto-detected for Lambda Node.js runtimes
    s3        = optional(any, null)  # bool or string
    variables = optional(map(string), {})
  })
}

variable "secrets_config" {
  description = "Secrets configuration. Key = env var name, Value = secret reference. Supports: 'secret-name' (whole secret) or 'secret-name:json-key' (specific JSON key)"
  type        = map(string)
  default     = {}
}

variable "global_config" {
  description = "Global configuration (database fields removed)"
  type = object({
    name           = string
    aws_region     = string
    environment    = string
    s3_enabled     = bool
    s3_bucket_name = optional(string, null)
  })
}