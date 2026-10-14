output "role_arn" {
  description = "IAM role ARN for GitHub Actions to assume"
  value       = aws_iam_role.github_actions.arn
}

output "role_name" {
  description = "IAM role name"
  value       = aws_iam_role.github_actions.name
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN"
  value       = local.oidc_provider_arn
}
