# -----------------------------------------------------------------------------
# AWS provider configuration.
#
# Terraform init and the S3 backend always run as the CodeBuild role in the
# repo account. Resource CRUD assumes the execution/infra role supplied by the
# pipeline (TF_VAR_tf_execution_role_arn) so each target account only needs
# permissions for the resources it hosts - never the state bucket.
# -----------------------------------------------------------------------------
variable "tf_execution_role_arn" {
  description = "ARN the AWS provider assumes for resource CRUD. Empty = run as the CodeBuild role (repo account)."
  type        = string
  default     = ""
}

variable "tf_role_session_name" {
  description = "Session name used when assuming tf_execution_role_arn. Ephemeral so Plan and Apply builds can use distinct session names (Terraform 1.10+)."
  type        = string
  default     = "terraform-pipeline"
  ephemeral   = true
}

provider "aws" {
  region = var.region
  assume_role {
    role_arn     = var.tf_execution_role_arn != "" ? var.tf_execution_role_arn : null
    session_name = var.tf_role_session_name
  }
  default_tags {
    tags = var.tags
  }
}

provider "null" {}