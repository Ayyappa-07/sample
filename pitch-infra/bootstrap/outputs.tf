output "state_bucket_name" {
  description = "S3 bucket for Terraform state"
  value       = var.create_shared_backend ? aws_s3_bucket.state[0].id : "pitchai-terraform-state"
}

output "lock_table_name" {
  description = "DynamoDB table for state locking"
  value       = var.create_shared_backend ? aws_dynamodb_table.lock[0].name : "pitchai-terraform-lock"
}

output "terraform_role_arn" {
  description = "IAM role ARN for GitHub Actions (set as AWS_ROLE_ARN_<ENV> secret)"
  value       = aws_iam_role.terraform.arn
}

output "oidc_provider_arn" {
  description = "GitHub OIDC provider ARN"
  value       = local.oidc_provider_arn
}

output "backend_config" {
  description = "Paste into environments/<env>/backend.hcl"
  value       = <<-EOT
    bucket         = "${var.create_shared_backend ? aws_s3_bucket.state[0].id : "pitchai-terraform-state"}"
    key            = "pitchai/${var.environment}/terraform.tfstate"
    region         = "${var.region}"
    encrypt        = true
    dynamodb_table = "${var.create_shared_backend ? aws_dynamodb_table.lock[0].name : "pitchai-terraform-lock"}"
  EOT
}
