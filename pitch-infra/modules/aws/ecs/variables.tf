# =============================================================================
# AWS ECS MODULE - VARIABLES
# =============================================================================

variable "cluster_name" {
  description = "Name of the ECS cluster"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where ECS tasks will run"
  type        = string
}

variable "subnet_ids" {
  description = "List of subnet IDs for ECS tasks"
  type        = list(string)
}

variable "enable_container_insights" {
  description = "Enable CloudWatch Container Insights"
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 365
}

variable "capacity_providers" {
  description = "List of capacity providers (FARGATE, FARGATE_SPOT)"
  type        = list(string)
  default     = ["FARGATE", "FARGATE_SPOT"]
}

variable "default_capacity_provider" {
  description = "Default capacity provider for the cluster"
  type        = string
  default     = "FARGATE"
}

variable "kms_key_arn" {
  description = "KMS key ARN for encrypting logs"
  type        = string
  default     = ""
}

variable "container_port" {
  description = "Application container port (used by SG ingress rule)"
  type        = number
  default     = 5000
}

variable "allowed_ingress_cidrs" {
  description = "CIDR blocks allowed to access ECS tasks"
  type        = list(string)
  default     = []
}

variable "allowed_ingress_security_group_ids" {
  description = "Security group IDs allowed to access ECS tasks (e.g. ALB SG)"
  type        = list(string)
  default     = []
}

variable "secret_arns" {
  description = "Additional secret ARNs the execution role needs access to (e.g. RDS-managed secrets)"
  type        = list(string)
  default     = []
}

variable "s3_bucket_arns" {
  description = "S3 bucket ARNs the task role needs access to"
  type        = list(string)
  default     = []
}

variable "enable_ses_access" {
  description = "Grant SES SendEmail/SendRawEmail to the task role"
  type        = bool
  default     = false
}

variable "enable_sns_publish" {
  description = "Grant SNS Publish to the task role"
  type        = bool
  default     = false
}

variable "sns_topic_arns" {
  description = "SNS topic ARNs the task role is allowed to publish to (empty = all topics in account)"
  type        = list(string)
  default     = []
}

variable "enable_sns_sms" {
  description = "Grant SNS Publish on Resource \"*\" so the app can send SMS to bare phone numbers. Required for sendSms(); topic-scoped Publish does NOT cover it."
  type        = bool
  default     = false
}

variable "ses_identity_arn" {
  description = "ARN of this environment's SES sending identity. Scopes ses:SendEmail to it instead of \"*\"."
  type        = string
  default     = ""
}

variable "ses_configuration_set_arn" {
  description = "ARN of this environment's SES configuration set. Must be granted alongside the identity when the identity has a default configuration set."
  type        = string
  default     = ""
}

variable "ses_from_domain" {
  description = "Restrict ses:FromAddress to this domain (e.g. qa.pitch.openn.com). Empty = no From restriction."
  type        = string
  default     = ""
}

variable "ses_allowed_recipient_domains" {
  description = "If set, the task role may ONLY email these recipient domains. Intended as a non-prod blast guard once the account leaves the SES sandbox. Empty = unrestricted."
  type        = list(string)
  default     = []
}

variable "ses_production_access" {
  description = "Whether the AWS account has SES production access (i.e. is OUT of the sandbox) in this region. Purely a declaration — AWS exposes no Terraform data source for it. Setting it true with an empty ses_allowed_recipient_domains fails the plan, because the sandbox is what makes the empty allowlist safe."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "sms_origination_identity_arn" {
  description = "ARN of the origination identity (sender ID / pool / phone number) used for SMS. May belong to another AWS account when shared via AWS RAM — Pitch uses Openn's AU-registered OPENN sender ID so both products share one opt-out list. Empty disables the SMS grant."
  type        = string
  default     = ""
}

variable "ses_allow_unrestricted_recipients" {
  description = "Declare that this environment may email ANY recipient. Only meaningful with ses_production_access = true and an empty ses_allowed_recipient_domains — it is the explicit opt-out from the recipient-allowlist guard, intended for prod, where sending to arbitrary customer addresses is the point. Leaving it false keeps 'someone forgot the allowlist' a loud plan-time failure."
  type        = bool
  default     = false
}
