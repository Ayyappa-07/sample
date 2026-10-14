# =============================================================================
# AWS OBSERVABILITY MODULE - OUTPUTS
# =============================================================================

output "security_alerts_topic_arn" {
  description = "SNS topic ARN for security alerts"
  value       = aws_sns_topic.security_alerts.arn
}

output "security_alerts_topic_name" {
  description = "SNS topic name for security alerts"
  value       = aws_sns_topic.security_alerts.name
}

output "operational_alerts_topic_arn" {
  description = "SNS topic ARN for operational alerts"
  value       = aws_sns_topic.operational_alerts.arn
}

output "operational_alerts_topic_name" {
  description = "SNS topic name for operational alerts"
  value       = aws_sns_topic.operational_alerts.name
}

output "dashboard_name" {
  description = "CloudWatch dashboard name"
  value       = var.create_dashboard ? aws_cloudwatch_dashboard.main[0].dashboard_name : null
}

output "dashboard_arn" {
  description = "CloudWatch dashboard ARN"
  value       = var.create_dashboard ? aws_cloudwatch_dashboard.main[0].dashboard_arn : null
}
