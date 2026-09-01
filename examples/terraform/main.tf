terraform {
  required_version = ">= 1.0.0"

  required_providers {
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0"
    }
  }

  # S3 remote state.
  # The per-environment S3 settings live in envs/<env>.tfbackend (e.g.
  # envs/dev.tfbackend). CodeBuild passes that file to `terraform init` via
  # -backend-config and can override individual settings with the
  # TF_BACKEND_BUCKET / TF_BACKEND_KEY / TF_BACKEND_REGION env vars.
  # The block must stay near-empty because backend settings cannot be variables.
  backend "s3" {}
}

provider "null" {}

# -----------------------------------------------------------------------------
# Variables - environment is injected by the pipeline via -var; the remaining
# variables come from the per-environment tfvars file (envs/<env>.tfvars)
# selected by the TfVarsFile stack parameter.
# -----------------------------------------------------------------------------
variable "environment" {
  description = "Deployment environment (dev/test/prod). Injected by the pipeline."
  type        = string
}

variable "message" {
  description = "Message to print. Set per environment in the tfvars file."
  type        = string
  default     = "Hello World"
}

variable "region" {
  description = "AWS region for this environment."
  type        = string
  default     = "us-east-1"
}

variable "tags" {
  description = "Common resource tags for this environment."
  type        = map(string)
  default = {
    ManagedBy = "Terraform"
  }
}

# -----------------------------------------------------------------------------
# Resources
# -----------------------------------------------------------------------------
resource "null_resource" "hello" {
  triggers = {
    environment = var.environment
    message     = var.message
    region      = var.region
  }

  provisioner "local-exec" {
    command = "echo '${var.message} (env=${var.environment})'"
  }
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "message" {
  description = "Greeting for the deployed environment."
  value       = "${var.message} (env=${var.environment})"
}

output "environment" {
  description = "Active environment."
  value       = var.environment
}

output "region" {
  description = "Active region."
  value       = var.region
}