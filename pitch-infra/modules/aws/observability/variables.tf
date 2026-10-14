# =============================================================================
# AWS OBSERVABILITY MODULE - VARIABLES
# =============================================================================

variable "environment" {
  description = "Deployment environment"
  type        = string
}

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
}

variable "alarm_email_endpoints" {
  description = "Email addresses to receive alarm notifications"
  type        = list(string)
  default     = []
}

variable "alarm_slack_webhook_url" {
  description = "Slack webhook URL for alarm notifications (stored in Secrets Manager)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "enable_security_alarms" {
  description = "Enable security-related CloudWatch alarms"
  type        = bool
  default     = true
}

variable "enable_cost_alarms" {
  description = "Enable cost anomaly alarms"
  type        = bool
  default     = true
}

variable "monthly_budget_usd" {
  description = "Monthly budget in USD for cost alarm"
  type        = number
  default     = 1000
}

variable "cloudtrail_log_group_name" {
  description = "CloudTrail CloudWatch log group name for security alarms"
  type        = string
  default     = ""
}

variable "ecs_cluster_name" {
  description = "ECS cluster name for container alarms"
  type        = string
  default     = ""
}

variable "vpc_id" {
  description = "VPC ID for flow log alarms"
  type        = string
  default     = ""
}

variable "create_dashboard" {
  description = "Create CloudWatch dashboard"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "enable_sms" {
  description = "Whether SMS-related CloudWatch alarms should be enabled"
  type        = bool
}

variable "sms_monthly_spend_limit_usd" {
  description = "Monthly SMS spend limit in USD (from AWS support case)"
  type        = number
  default     = 350
}

variable "ecs_service_name" {
  description = "ECS service name used for CloudWatch service-level metrics"
  type        = string
}

variable "alb_arn_suffix" {
  description = "ALB ARN suffix used for Application Load Balancer metrics"
  type        = string
  default     = ""
}

variable "alb_target_group_arn_suffix" {
  description = "Target group ARN suffix used for Application Load Balancer metrics"
  type        = string
  default     = ""
}

variable "alb_5xx_error_pct" {
  description = "ALB target 5xx response percentage threshold"
  type        = number
  default     = 5
}

variable "canary_base_url" {
  description = "Base URL used by CloudWatch Synthetics canaries"
  type        = string
  default     = ""
}

variable "enable_synthetics_monitoring" {
  description = "Enable migrated Synthetics canaries"
  type        = bool
  default     = false
}

variable "app_log_group_name" {
  description = "CloudWatch log group containing application logs"
  type        = string
}
