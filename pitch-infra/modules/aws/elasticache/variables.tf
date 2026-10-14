# =============================================================================
# AWS ELASTICACHE REDIS MODULE - VARIABLES
# =============================================================================

# -----------------------------------------------------------------------------
# REQUIRED
# -----------------------------------------------------------------------------

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the Redis cluster will be deployed"
  type        = string
}

variable "subnet_ids" {
  description = "List of subnet IDs for the ElastiCache subnet group (use private subnets)"
  type        = list(string)
}

# -----------------------------------------------------------------------------
# NETWORKING
# -----------------------------------------------------------------------------

variable "allowed_security_group_ids" {
  description = "Security group IDs allowed to access Redis on port 6379"
  type        = list(string)
  default     = []
}

variable "port" {
  description = "Redis port"
  type        = number
  default     = 6379
}

# -----------------------------------------------------------------------------
# CLUSTER CONFIGURATION
# -----------------------------------------------------------------------------

variable "node_type" {
  description = "ElastiCache node instance type"
  type        = string
  default     = "cache.t3.medium"
}

variable "num_cache_clusters" {
  description = "Number of cache clusters (nodes) in the replication group (1 = primary only, 2+ = primary + replicas)"
  type        = number
  default     = 2
}

variable "engine_version" {
  description = "Redis engine version"
  type        = string
  default     = "7.1"
}

variable "parameter_group_family" {
  description = "ElastiCache parameter group family"
  type        = string
  default     = "redis7"
}

# -----------------------------------------------------------------------------
# ENCRYPTION
# -----------------------------------------------------------------------------

variable "transit_encryption_enabled" {
  description = "Enable encryption in transit (TLS). Required for AUTH token."
  type        = bool
  default     = true
}

variable "at_rest_encryption_enabled" {
  description = "Enable encryption at rest (KMS)"
  type        = bool
  default     = true
}

variable "kms_key_arn" {
  description = "KMS key ARN for at-rest encryption (uses AWS managed key if not specified)"
  type        = string
  default     = null
}

# -----------------------------------------------------------------------------
# BACKUP / MAINTENANCE
# -----------------------------------------------------------------------------

variable "snapshot_retention_limit" {
  description = "Number of days to retain automatic snapshots (0 to disable)"
  type        = number
  default     = 7
}

variable "snapshot_window" {
  description = "Daily time range for automatic snapshots (UTC)"
  type        = string
  default     = "03:00-05:00"
}

variable "maintenance_window" {
  description = "Weekly maintenance window (UTC)"
  type        = string
  default     = "mon:05:00-mon:07:00"
}

# -----------------------------------------------------------------------------
# ALARMS
# -----------------------------------------------------------------------------

variable "alarm_sns_topic_arns" {
  description = "SNS topic ARNs for CloudWatch alarm notifications (alarms disabled if empty)"
  type        = list(string)
  default     = []
}

# -----------------------------------------------------------------------------
# TAGS
# -----------------------------------------------------------------------------

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
