variable "bucket_name" {
  description = "Name of the S3 bucket"
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the KMS key for SSE-KMS encryption. If null, uses AWS managed key (aws/s3)."
  type        = string
  default     = null
}

variable "enable_versioning" {
  description = "Enable versioning on the bucket"
  type        = bool
  default     = true
}

variable "enable_lifecycle_rules" {
  description = "Enable lifecycle rules for transitioning objects to cheaper storage classes"
  type        = bool
  default     = true
}

variable "ia_transition_days" {
  description = "Number of days after which objects transition to Standard-IA"
  type        = number
  default     = 90
}

variable "glacier_transition_days" {
  description = "Number of days after which objects transition to Glacier"
  type        = number
  default     = 365
}

variable "cors_allowed_origins" {
  description = "List of allowed origins for CORS configuration"
  type        = list(string)
  default     = []
}

variable "cors_allowed_methods" {
  description = "List of allowed HTTP methods for CORS configuration"
  type        = list(string)
  default     = ["GET", "PUT", "POST", "DELETE"]
}

variable "logging_bucket_id" {
  description = "ID of the bucket to use for access logging. If null, logging is disabled."
  type        = string
  default     = null
}

variable "force_destroy" {
  description = "Allow destruction of the bucket even if it contains objects"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
