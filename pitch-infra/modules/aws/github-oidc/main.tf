# =============================================================================
# GitHub OIDC Provider + Deploy Role
# =============================================================================
# Allows GitHub Actions to assume an IAM role via OIDC federation.
# No long-lived credentials needed.
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  oidc_provider_url = "https://token.actions.githubusercontent.com"
  oidc_audience     = "sts.amazonaws.com"
}

# -----------------------------------------------------------------------------
# OIDC PROVIDER (one per account — use count to skip if already exists)
# -----------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url = local.oidc_provider_url

  client_id_list = [local.oidc_audience]

  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]

  tags = var.tags
}

locals {
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
}

# -----------------------------------------------------------------------------
# IAM ROLE — assumed by GitHub Actions
# -----------------------------------------------------------------------------

resource "aws_iam_role" "github_actions" {
  name = var.role_name
  path = "/github-actions/"

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
            "token.actions.githubusercontent.com:aud" = local.oidc_audience
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = length(var.oidc_subject_claims) > 0 ? var.oidc_subject_claims : [
              for repo in var.github_repositories : "repo:${repo}:*"
            ]
          }
        }
      }
    ]
  })

  max_session_duration = 3600

  tags = var.tags
}

# -----------------------------------------------------------------------------
# POLICY — Terraform operations (plan/apply)
# -----------------------------------------------------------------------------

resource "aws_iam_role_policy" "terraform" {
  count = var.attach_terraform_policy ? 1 : 0

  name = "${var.role_name}-terraform"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "TerraformStateAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
        ]
        Resource = [
          "arn:aws:s3:::${var.terraform_state_bucket}",
          "arn:aws:s3:::${var.terraform_state_bucket}/*",
        ]
      },
      {
        Sid    = "TerraformPlanApply"
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
          "secretsmanager:*",
          "kms:*",
          "elasticloadbalancing:*",
          "application-autoscaling:*",
          "route53:*",
          "acm:*",
          "wafv2:*",
          "scheduler:*",
          "events:*",
          "ssm:*",
          "servicediscovery:*",
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
          "iam:RemoveRoleFromInstanceProfile",
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
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# POLICY — ECR push + ECS deploy (for app deploy workflow)
# -----------------------------------------------------------------------------

resource "aws_iam_role_policy" "deploy" {
  count = var.attach_deploy_policy ? 1 : 0

  name = "${var.role_name}-deploy"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRAuth"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
        ]
        Resource = "*"
      },
      {
        Sid    = "ECRPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
        ]
        Resource = var.ecr_repository_arns
      },
      {
        Sid    = "ECSRegisterTaskDef"
        Effect = "Allow"
        Action = [
          "ecs:RegisterTaskDefinition",
          "ecs:DescribeTaskDefinition",
        ]
        Resource = "*"
      },
      {
        Sid    = "ECSDeployService"
        Effect = "Allow"
        Action = [
          "ecs:UpdateService",
          "ecs:DescribeServices",
          "ecs:RunTask",
          "ecs:StopTask",
          "ecs:DescribeTasks",
          "ecs:ListTasks",
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "ecs:cluster" = var.ecs_cluster_arns
          }
        }
      },
      {
        Sid      = "ECSPassRole"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = var.ecs_task_role_arns
      },
      {
        # Surface failed one-off task logs (e.g. migrations) in the Actions
        # output instead of a bare "task failed". DescribeLogStreams finds the
        # task's stream; GetLogEvents reads it. Read-only, scoped to the
        # cluster log groups.
        Sid    = "ReadTaskLogsForCI"
        Effect = "Allow"
        Action = [
          "logs:DescribeLogStreams",
          "logs:GetLogEvents",
        ]
        Resource = flatten([for arn in var.log_group_arns : [arn, "${arn}:*"]])
      },
    ]
  })
}
