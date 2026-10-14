variable "environment" {
  description = "Environment name (qa, staging, prod)"
  type        = string

  validation {
    condition     = contains(["qa", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: qa, staging, prod."
  }
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-2"
}

variable "github_repositories" {
  description = "GitHub repos allowed to assume the Terraform role (format: org/repo)"
  type        = list(string)
  default     = ["OpennRE/pitch-infra"]
}

variable "create_oidc_provider" {
  description = "Create the GitHub OIDC provider (set false if it already exists in this account)"
  type        = bool
  default     = false
}

variable "create_shared_backend" {
  description = "Create the account-level state bucket and lock table. True only for the first bootstrap run in an account; false for per-environment runs, which need only the IAM role."
  type        = bool
  default     = false
}
