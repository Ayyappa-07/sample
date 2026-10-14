# =============================================================================
# BOOTSTRAP — Run once per AWS account
# =============================================================================
# Creates the Terraform state bucket, DynamoDB lock table, OIDC provider, and
# an IAM role that GitHub Actions + developers assume to run Terraform.
#
# Usage:
#   cd bootstrap
#   export AWS_PROFILE=pitchai-<env>   # or use SSO
#   terraform init
#   terraform apply -var="environment=qa"
#
# After apply, note the outputs and plug them into:
#   environments/<env>/backend.hcl
#   GitHub repo secret: AWS_ROLE_ARN_<ENV>
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # State persists in the (already-existing) state bucket under a bootstrap key.
  backend "s3" {}
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "pitchai"
      Environment = var.environment
      ManagedBy   = "terraform-bootstrap"
    }
  }
}

# -----------------------------------------------------------------------------
# DATA SOURCES
# -----------------------------------------------------------------------------
data "aws_caller_identity" "current" {}
# -----------------------------------------------------------------------------
# S3 STATE BUCKET
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "state" {
  count  = var.create_shared_backend ? 1 : 0
  bucket = "pitchai-terraform-state"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  count  = var.create_shared_backend ? 1 : 0
  bucket = aws_s3_bucket.state[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  count  = var.create_shared_backend ? 1 : 0
  bucket = aws_s3_bucket.state[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  count  = var.create_shared_backend ? 1 : 0
  bucket = aws_s3_bucket.state[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# -----------------------------------------------------------------------------
# DYNAMODB LOCK TABLE
# -----------------------------------------------------------------------------

resource "aws_dynamodb_table" "lock" {
  count        = var.create_shared_backend ? 1 : 0
  name         = "pitchai-terraform-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  lifecycle {
    prevent_destroy = true
  }
}

# -----------------------------------------------------------------------------
# GITHUB OIDC PROVIDER
# -----------------------------------------------------------------------------

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

locals {
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

# -----------------------------------------------------------------------------
# TERRAFORM APPLY ROLE (assumed by GitHub Actions via OIDC)
# -----------------------------------------------------------------------------

resource "aws_iam_role" "terraform" {
  name = "pitchai-terraform-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = local.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = [
              for repo in var.github_repositories : "repo:${repo}:*"
            ]
          }
        }
      }
    ]
  })

  max_session_duration = 7200
}

resource "aws_iam_role_policy" "terraform_state" {
  name = "terraform-state-access"
  role = aws_iam_role.terraform.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          var.create_shared_backend ? aws_s3_bucket.state[0].arn : "arn:aws:s3:::pitchai-terraform-state",
          var.create_shared_backend ? "${aws_s3_bucket.state[0].arn}/*" : "arn:aws:s3:::pitchai-terraform-state/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:DeleteItem"
        ]
        Resource = var.create_shared_backend ? aws_dynamodb_table.lock[0].arn : "arn:aws:dynamodb:${var.region}:${data.aws_caller_identity.current.account_id}:table/pitchai-terraform-lock"
      }
    ]
  })
}

resource "aws_iam_role_policy" "terraform_infra" {
  name = "terraform-infra-management"
  role = aws_iam_role.terraform.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InfraManagement"
        Effect = "Allow"
        Action = [
          "ec2:*",
          "ecs:*",
          "ecr:*",
          "elasticache:*",
          "rds:*",
          "s3:*",
          "logs:*",
          "cloudwatch:*",
          "sns:*",
          "ses:*",
          "secretsmanager:*",
          "kms:*",
          "elasticloadbalancing:*",
          "route53:*",
          "acm:*",
          "wafv2:*",
          "events:*",
          "scheduler:*",
          "budgets:*",
          "application-autoscaling:*",
          "servicediscovery:*"
        ]
        Resource = "*"
      },
      {
        Sid    = "IAMScoped"
        Effect = "Allow"
        Action = [
          "iam:Get*",
          "iam:List*",
          "iam:PassRole",
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:CreateServiceLinkedRole",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:UpdateAssumeRolePolicy",
          "iam:CreateInstanceProfile",
          "iam:DeleteInstanceProfile",
          "iam:AddRoleToInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile"
        ]
        Resource = "arn:aws:iam::*:role/pitchai-*"
      },
      {
        Sid    = "IAMOIDCProvider"
        Effect = "Allow"
        Action = [
          "iam:CreateOpenIDConnectProvider",
          "iam:DeleteOpenIDConnectProvider",
        ]
        Resource = "arn:aws:iam::*:oidc-provider/token.actions.githubusercontent.com"
      }
    ]
  })
}
