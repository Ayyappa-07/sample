# =============================================================================
# AWS RDS MODULE - OUTPUTS
# =============================================================================

output "db_instance_id" {
  description = "ID of the RDS instance"
  value       = aws_db_instance.this.id
}

output "db_instance_arn" {
  description = "ARN of the RDS instance"
  value       = aws_db_instance.this.arn
}

output "db_instance_endpoint" {
  description = "Connection endpoint (host:port)"
  value       = aws_db_instance.this.endpoint
  sensitive   = true
}

output "db_instance_address" {
  description = "Hostname of the RDS instance"
  value       = aws_db_instance.this.address
  sensitive   = true
}

output "db_instance_port" {
  description = "Port of the RDS instance"
  value       = aws_db_instance.this.port
}

output "db_name" {
  description = "Name of the default database"
  value       = aws_db_instance.this.db_name
}

output "db_subnet_group_name" {
  description = "Name of the DB subnet group"
  value       = aws_db_subnet_group.this.name
}

output "security_group_id" {
  description = "Security group ID for the RDS instance"
  value       = aws_security_group.this.id
}

output "replica_endpoint" {
  description = "Connection endpoint of the read replica"
  value       = var.enable_read_replica ? aws_db_instance.replica[0].endpoint : null
}

output "replica_address" {
  description = "Hostname of the read replica"
  value       = var.enable_read_replica ? aws_db_instance.replica[0].address : null
}

output "monitoring_role_arn" {
  description = "ARN of the enhanced monitoring IAM role"
  value       = var.enhanced_monitoring_interval > 0 ? aws_iam_role.monitoring[0].arn : null
}

output "master_user_secret_arn" {
  description = "ARN of the Secrets Manager secret for the master password (when managed by RDS)"
  value       = var.manage_master_user_password ? aws_db_instance.this.master_user_secret[0].secret_arn : null
}
