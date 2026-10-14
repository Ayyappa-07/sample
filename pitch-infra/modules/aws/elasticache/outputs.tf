# =============================================================================
# AWS ELASTICACHE REDIS MODULE - OUTPUTS
# =============================================================================

output "replication_group_id" {
  description = "ID of the ElastiCache replication group"
  value       = aws_elasticache_replication_group.this.id
}

output "primary_endpoint_address" {
  description = "Primary endpoint address for write operations"
  value       = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "reader_endpoint_address" {
  description = "Reader endpoint address for read operations (load-balanced across replicas)"
  value       = aws_elasticache_replication_group.this.reader_endpoint_address
}

output "port" {
  description = "Redis port"
  value       = aws_elasticache_replication_group.this.port
}

output "security_group_id" {
  description = "Security group ID for the Redis cluster"
  value       = aws_security_group.this.id
}

output "auth_token_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the Redis AUTH token"
  value       = aws_secretsmanager_secret.auth_token.arn
}
