# =============================================================================
# PITCH INFRASTRUCTURE - OUTPUTS
# =============================================================================

# Networking
output "vpc_id" {
  value = module.networking.vpc_id
}

output "private_subnet_ids" {
  value = module.networking.private_subnet_ids
}

output "nat_gateway_ips" {
  description = "NAT Gateway public IPs (for allowlisting in external services)"
  value       = module.networking.nat_gateway_public_ips
}

# ECS
output "ecs_cluster_name" {
  value = module.ecs.cluster_name
}

output "ecs_service_name" {
  value = aws_ecs_service.app.name
}

output "task_execution_role_arn" {
  value = module.ecs.task_execution_role_arn
}

output "task_role_arn" {
  value = module.ecs.task_role_arn
}

# ECR
output "ecr_repository_url" {
  value = module.ecr.repository_url
}

# ALB
output "alb_dns_name" {
  description = "ALB DNS name"
  value       = aws_lb.this.dns_name
}

output "alb_zone_id" {
  description = "ALB hosted zone ID (for Route53 alias records)"
  value       = aws_lb.this.zone_id
}

output "app_url" {
  description = "Application URL"
  value       = var.app_domain != "" ? "https://${var.app_domain}" : "http://${aws_lb.this.dns_name}"
}

output "cloudfront_domain_name" {
  description = "CloudFront distribution domain name (null if disabled)"
  value       = var.enable_cloudfront ? aws_cloudfront_distribution.this[0].domain_name : null
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID (for cache invalidation in CI)"
  value       = var.enable_cloudfront ? aws_cloudfront_distribution.this[0].id : null
}

# DNS / TLS
output "route53_zone_id" {
  description = "Route53 hosted zone ID (null if no zone created)"
  value       = local.create_dns && !local.use_existing_zone && var.create_dns_zone ? aws_route53_zone.this[0].zone_id : null
}

output "route53_nameservers" {
  description = "Nameservers for the hosted zone (delegate these from your registrar)"
  value       = local.create_dns && !local.use_existing_zone && var.create_dns_zone ? aws_route53_zone.this[0].name_servers : []
}

output "acm_certificate_arn" {
  description = "ACM certificate ARN (auto-created or provided)"
  value       = local.cert_arn != "" ? local.cert_arn : null
}

# Database
output "rds_endpoint" {
  description = "RDS connection endpoint"
  value       = module.rds.db_instance_endpoint
  sensitive   = true
}

output "rds_master_secret_arn" {
  description = "Secrets Manager ARN for the RDS master password"
  value       = module.rds.master_user_secret_arn
}

# Redis
output "redis_primary_endpoint" {
  description = "Redis primary endpoint"
  value       = module.elasticache.primary_endpoint_address
}

output "redis_auth_secret_arn" {
  description = "Secrets Manager ARN for the Redis AUTH token"
  value       = module.elasticache.auth_token_secret_arn
}

# S3
output "s3_bucket_name" {
  value = module.s3.bucket_id
}

output "s3_bucket_arn" {
  value = module.s3.bucket_arn
}

# Secrets
output "app_secret_arns" {
  description = "Map of application secret names to their ARNs"
  value       = module.secrets.secret_arns
}

# Messaging — the values developers need to configure the app (PA-111).
# SES_FROM_EMAIL / SES_REGION / SNS_REGION are read by src/lib/config.ts and get
# set as GitHub Actions environment variables on OpennRE/Pitch, matching how the
# Openn SSO config is managed.
output "messaging_app_config" {
  description = "Env-var values for the Pitch app's SES/SNS integration"
  value = {
    # Same local the ECS task definition uses — these two must not drift.
    SES_FROM_EMAIL = local.ses_from_email
    SES_REGION     = var.region
    SNS_REGION     = var.region
    # Not read by the app yet — src/lib/integrations/ses.ts must pass
    # ConfigurationSetName for per-env metrics/suppression to apply.
    SES_CONFIGURATION_SET = var.app_domain != "" ? aws_sesv2_configuration_set.this[0].configuration_set_name : ""
  }
}

output "ses_identity" {
  description = "Verified SES sending domain for this environment"
  value       = var.app_domain != "" ? aws_ses_domain_identity.this[0].domain : ""
}

output "ses_configuration_set_name" {
  description = "Default configuration set attached to the sending identity. Per-env reputation metrics, suppression list and sending kill switch hang off this."
  value       = var.app_domain != "" ? aws_sesv2_configuration_set.this[0].configuration_set_name : ""
}

# Observability
output "operational_alerts_topic_arn" {
  value = module.observability.operational_alerts_topic_arn
}

output "security_alerts_topic_arn" {
  value = module.observability.security_alerts_topic_arn
}

# CI/CD
output "github_actions_role_arn" {
  description = "IAM role ARN for GitHub Actions (set as AWS_ROLE_ARN_<ENV> secret)"
  value       = module.github_oidc.role_arn
}
