###############################################################################
# Secrets Manager — application secrets (API keys, tokens, etc.)
###############################################################################

resource "aws_secretsmanager_secret" "this" {
  for_each = var.secrets

  name        = "${var.project_name}/${each.key}"
  description = each.value.description

  kms_key_id                     = var.kms_key_arn
  recovery_window_in_days        = try(each.value.recovery_window_in_days, 7)
  force_overwrite_replica_secret = false

  tags = merge(var.tags, {
    Name      = "${var.project_name}/${each.key}"
    SecretKey = each.key
  })
}

# Seed each secret with a sentinel placeholder value. AWS rejects an empty
# SecretString (PutSecretValue: "You must provide either SecretString or
# SecretBinary"), so the placeholder must be non-empty. Real values are injected
# manually or via CI/CD; ignore_changes keeps Terraform from ever reverting them.
resource "aws_secretsmanager_secret_version" "this" {
  for_each = var.secrets

  secret_id     = aws_secretsmanager_secret.this[each.key].id
  secret_string = "PLACEHOLDER_SET_ME"

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# Resource policy restricting read access to specified IAM role ARNs.
resource "aws_secretsmanager_secret_policy" "this" {
  for_each = length(var.allowed_role_arns) > 0 ? var.secrets : {}

  secret_arn = aws_secretsmanager_secret.this[each.key].arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowRoleAccess"
        Effect = "Allow"
        Principal = {
          AWS = var.allowed_role_arns
        }
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
        ]
        Resource = "*"
      }
    ]
  })
}
