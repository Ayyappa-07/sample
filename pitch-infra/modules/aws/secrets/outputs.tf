###############################################################################
# Outputs — Secrets Manager module
###############################################################################

output "secret_arns" {
  description = "Map of secret key to its ARN."
  value = {
    for key, secret in aws_secretsmanager_secret.this : key => secret.arn
  }
}

output "secret_names" {
  description = "Map of secret key to its full secret name (project_name/key)."
  value = {
    for key, secret in aws_secretsmanager_secret.this : key => secret.name
  }
}
