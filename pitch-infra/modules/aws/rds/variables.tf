# =============================================================================
# AWS RDS MODULE - VARIABLES
# =============================================================================

# -----------------------------------------------------------------------------
# REQUIRED
# -----------------------------------------------------------------------------

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the RDS instance will be deployed"
  type        = string
}

variable "subnet_ids" {
  description = "List of subnet IDs for the DB subnet group (use private subnets)"
  type        = list(string)
}

variable "engine" {
  description = "Database engine (postgres, mysql, mariadb)"
  type        = string

  validation {
    condition     = contains(["postgres", "mysql", "mariadb"], var.engine)
    error_message = "Engine must be one of: postgres, mysql, mariadb."
  }
}

variable "engine_version" {
  description = "Database engine version"
  type        = string
}

variable "instance_class" {
  description = "RDS instance class (e.g., db.t3.medium, db.r6g.large)"
  type        = string
}

variable "master_username" {
  description = "Master username for the database"
  type        = string
}

variable "master_password" {
  description = "Master password for the database (ignored if manage_master_user_password is true)"
  type        = string
  sensitive   = true
  default     = null
}

variable "manage_master_user_password" {
  description = "Let RDS manage the master password via Secrets Manager (recommended for SOC 2)"
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# NETWORKING
# -----------------------------------------------------------------------------

variable "port" {
  description = "Database port (defaults to 5432 for postgres, 3306 for mysql/mariadb)"
  type        = number
  default     = null
}

variable "allowed_security_group_ids" {
  description = "Security group IDs allowed to access the database"
  type        = list(string)
  default     = []
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to access the database (prefer security groups)"
  type        = list(string)
  default     = []
}

# -----------------------------------------------------------------------------
# STORAGE
# -----------------------------------------------------------------------------

variable "allocated_storage" {
  description = "Allocated storage in GB"
  type        = number
  default     = 20
}

variable "max_allocated_storage" {
  description = "Maximum storage for autoscaling in GB (0 to disable)"
  type        = number
  default     = 100
}

variable "storage_type" {
  description = "Storage type (gp3, io1, io2)"
  type        = string
  default     = "gp3"
}

variable "iops" {
  description = "Provisioned IOPS (for io1/io2 storage types)"
  type        = number
  default     = 3000
}

# -----------------------------------------------------------------------------
# DATABASE
# -----------------------------------------------------------------------------

variable "database_name" {
  description = "Name of the default database to create"
  type        = string
  default     = null
}

variable "parameter_group_family" {
  description = "DB parameter group family (e.g., postgres16, mysql8.0)"
  type        = string
  default     = "postgres16"
}

variable "create_parameter_group" {
  description = "Create a custom parameter group with security defaults"
  type        = bool
  default     = true
}

variable "additional_parameters" {
  description = "Additional DB parameters to set"
  type = list(object({
    name         = string
    value        = string
    apply_method = optional(string, "immediate")
  }))
  default = []
}

# -----------------------------------------------------------------------------
# HIGH AVAILABILITY & BACKUPS (SOC 2 CC9.1)
# -----------------------------------------------------------------------------

variable "multi_az" {
  description = "Enable Multi-AZ deployment for high availability"
  type        = bool
  default     = true
}

variable "backup_retention_period" {
  description = "Number of days to retain automated backups (SOC 2 requires >= 7)"
  type        = number
  default     = 30

  validation {
    condition     = var.backup_retention_period >= 7
    error_message = "Backup retention must be at least 7 days for SOC 2 compliance."
  }
}

variable "backup_window" {
  description = "Preferred backup window (UTC)"
  type        = string
  default     = "03:00-04:00"
}

variable "maintenance_window" {
  description = "Preferred maintenance window (UTC)"
  type        = string
  default     = "Mon:04:00-Mon:05:00"
}

variable "skip_final_snapshot" {
  description = "Skip final snapshot on deletion (set to false for production)"
  type        = bool
  default     = false
}

variable "final_snapshot_identifier" {
  description = "Identifier for the final snapshot (defaults to project-name-rds-final-YYYYMMDD format)"
  type        = string
  default     = null
}

variable "deletion_protection" {
  description = "Enable deletion protection"
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# READ REPLICA
# -----------------------------------------------------------------------------

variable "enable_read_replica" {
  description = "Create a read replica for read scaling and DR"
  type        = bool
  default     = false
}

variable "replica_instance_class" {
  description = "Instance class for the read replica (defaults to primary instance class)"
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# ENCRYPTION (SOC 2 CC6.6)
# -----------------------------------------------------------------------------

variable "kms_key_arn" {
  description = "KMS key ARN for storage encryption (uses AWS managed key if not specified)"
  type        = string
  default     = null
}

# -----------------------------------------------------------------------------
# MONITORING (SOC 2 CC7.2)
# -----------------------------------------------------------------------------

variable "enhanced_monitoring_interval" {
  description = "Enhanced monitoring interval in seconds (0 to disable, 1/5/10/15/30/60)"
  type        = number
  default     = 60
}

variable "enable_performance_insights" {
  description = "Enable Performance Insights"
  type        = bool
  default     = true
}

variable "performance_insights_retention" {
  description = "Performance Insights retention period in days (7 or 731)"
  type        = number
  default     = 7
}

variable "cloudwatch_log_exports" {
  description = "List of log types to export to CloudWatch (defaults to engine-appropriate values if null)"
  type        = list(string)
  default     = null
}

# -----------------------------------------------------------------------------
# ALARMS
# -----------------------------------------------------------------------------

variable "enable_alarms" {
  description = "Enable CloudWatch alarms for the RDS instance"
  type        = bool
  default     = true
}

variable "alarm_sns_topic_arns" {
  description = "SNS topic ARNs for alarm notifications"
  type        = list(string)
  default     = []
}

variable "alarm_cpu_threshold" {
  description = "CPU utilization alarm threshold (%)"
  type        = number
  default     = 80
}

variable "alarm_free_storage_threshold" {
  description = "Free storage alarm threshold (bytes)"
  type        = number
  default     = 5368709120 # 5 GB
}

variable "alarm_freeable_memory_threshold" {
  description = "Freeable memory alarm threshold (bytes)"
  type        = number
  default     = 268435456 # 256 MB
}

variable "alarm_connections_threshold" {
  description = "Database connections alarm threshold"
  type        = number
  default     = 100
}

# -----------------------------------------------------------------------------
# SECURITY
# -----------------------------------------------------------------------------

variable "enable_iam_auth" {
  description = "Enable IAM database authentication"
  type        = bool
  default     = true
}

variable "ca_cert_identifier" {
  description = "CA certificate identifier for SSL/TLS"
  type        = string
  default     = "rds-ca-rsa2048-g1"
}

variable "auto_minor_version_upgrade" {
  description = "Enable automatic minor version upgrades (disable when pinning engine_version to avoid drift)"
  type        = bool
  default     = false
}

variable "apply_immediately" {
  description = "Apply changes immediately (may cause downtime)"
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# TAGS
# -----------------------------------------------------------------------------

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "log_retention_days" {
  description = "Number of days to retain RDS CloudWatch logs"
  type        = number
}