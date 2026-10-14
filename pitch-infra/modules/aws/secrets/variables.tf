###############################################################################
# Variables — Secrets Manager module
###############################################################################

variable "project_name" {
  description = "Project name used as prefix for secret names (e.g. pitchai)."
  type        = string
}

variable "secrets" {
  description = <<-EOT
    Map of secrets to create. Each key becomes the secret suffix.
    Example:
      {
        "anthropic-api-key" = { description = "Anthropic Claude API key" }
        "openai-api-key"    = { description = "OpenAI API key" }
        "browserless-api-key" = { description = "Browserless API key" }
        "nextauth-secret"   = { description = "NextAuth session signing secret" }
      }
  EOT
  type = map(object({
    description             = string
    recovery_window_in_days = optional(number, 7)
  }))
}

variable "kms_key_arn" {
  description = "ARN of a custom KMS key for encrypting secrets. If null, the AWS managed key (aws/secretsmanager) is used."
  type        = string
  default     = null
}

variable "allowed_role_arns" {
  description = "List of IAM role ARNs permitted to read the secrets."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags to apply to all secrets."
  type        = map(string)
  default     = {}
}
