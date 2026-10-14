# =============================================================================
# AWS ECS MODULE - OUTPUTS
# =============================================================================

output "cluster_id" {
  description = "ID of the ECS cluster"
  value       = aws_ecs_cluster.this.id
}

output "cluster_arn" {
  description = "ARN of the ECS cluster"
  value       = aws_ecs_cluster.this.arn
}

output "cluster_name" {
  description = "Name of the ECS cluster"
  value       = aws_ecs_cluster.this.name
}

output "task_execution_role_arn" {
  description = "ARN of the task execution role"
  value       = aws_iam_role.task_execution.arn
}

output "task_execution_role_name" {
  description = "Name of the task execution role"
  value       = aws_iam_role.task_execution.name
}

output "task_role_arn" {
  description = "ARN of the task role"
  value       = aws_iam_role.task.arn
}

output "task_role_name" {
  description = "Name of the task role"
  value       = aws_iam_role.task.name
}

output "log_group_name" {
  description = "CloudWatch log group name"
  value       = aws_cloudwatch_log_group.this.name
}

output "log_group_arn" {
  description = "CloudWatch log group ARN"
  value       = aws_cloudwatch_log_group.this.arn
}

output "tasks_security_group_id" {
  description = "Security group ID for ECS tasks"
  value       = aws_security_group.tasks.id
}

output "service_discovery_namespace_id" {
  description = "Service discovery namespace ID"
  value       = aws_service_discovery_private_dns_namespace.this.id
}

output "service_discovery_namespace_arn" {
  description = "Service discovery namespace ARN"
  value       = aws_service_discovery_private_dns_namespace.this.arn
}
