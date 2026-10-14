variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
}

variable "alb_arn" {
  description = "ARN of the ALB to protect with WAF"
  type        = string
}

variable "rate_limit" {
  description = "Maximum number of requests allowed per 5-minute period from a single IP"
  type        = number
  default     = 2000
}

variable "enable_geo_restriction" {
  description = "Enable geographic restriction to allow only specified countries"
  type        = bool
  default     = false
}

variable "allowed_country_codes" {
  description = "List of allowed country codes (ISO 3166-1 alpha-2). Used only if enable_geo_restriction is true"
  type        = list(string)
  default     = ["AU", "NZ"]
}

variable "log_retention_days" {
  description = "Number of days to retain WAF logs in CloudWatch"
  type        = number
  default     = 30
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "geo_rule_action" {
  description = "Action for the geo restriction rule"
  type        = string
  default     = "BLOCK"

  validation {
    condition     = contains(["BLOCK", "COUNT"], upper(var.geo_rule_action))
    error_message = "geo_rule_action must be BLOCK or COUNT."
  }
}
