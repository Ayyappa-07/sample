# =============================================================================
# AWS ECS MODULE
# =============================================================================
# ECS cluster with Fargate, task roles, and CloudWatch logging
# SOC 2 Controls: CC6.1 (task roles), CC6.8 (Fargate isolation), CC8.1 (managed runtime)
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  name_prefix = var.cluster_name

  common_tags = merge(var.tags, {
    Module = "aws/ecs"
  })

  # SES send permission covers every identity in THIS account plus this env's
  # configuration set.
  #
  # It deliberately does NOT pin the sending-domain identity ARN. SES evaluates
  # SendEmail/SendRawEmail against the RECIPIENT's identity too whenever that
  # recipient is itself a verified identity — which is exactly what sandbox
  # testing creates. Listing only the sending domain therefore breaks the moment
  # a tester's address is verified for sandbox delivery:
  #
  #   User '...pitchai-qa-cluster-task-role...' is not authorized to perform
  #   'ses:SendRawEmail' on resource '...:identity/akshay+a4@openn.com'
  #
  # (Observed on qa 2026-08-12: verifying a tester's address broke PDF email
  # delivery that had been working. Fix applied live, mirrored here.)
  #
  # identity/* is confined to this account, and the real control is the
  # ses:FromAddress condition below, which still pins the envelope sender to
  # this environment's own domain — so a task still cannot send AS another
  # environment, which is what the original scoping was protecting.
  ses_resource_arns = compact([
    var.ses_identity_arn != "" ? "${replace(var.ses_identity_arn, "/identity/.*/", "identity/")}*" : "",
    var.ses_configuration_set_arn,
  ])

  # ses:FromAddress pins the envelope sender to this env's domain.
  #
  # ses:Recipients (opt-in) confines who the app may email at all. Be clear
  # about what it is and is not: when the list is empty — as on qa today — the
  # condition is absent and there is NO recipient restriction in IAM. It is a
  # mechanism, not a standing guarantee, and an apply can leave it empty
  # unnoticed. What actually keeps non-prod safe today is the SES sandbox
  # (verified recipients only). The var_ses_production_access precondition on
  # aws_ecs_cluster.this below is what stops the two ever being off at once.
  #
  # Both conditions are omitted entirely when unset so the policy stays clean.
  # Two patterns on purpose: the app sends FromEmailAddress as a display-name
  # form ("Pitch <no-reply@domain>") when the caller supplies a name, and as a
  # bare address otherwise (src/lib/integrations/ses.ts). Matching only the bare
  # form would deny every named send.
  ses_conditions = merge(
    var.ses_from_domain != "" ? {
      StringLike = { "ses:FromAddress" = [
        "*@${var.ses_from_domain}",
        "*<*@${var.ses_from_domain}>",
      ] }
    } : {},
    length(var.ses_allowed_recipient_domains) > 0 ? {
      "ForAllValues:StringLike" = {
        "ses:Recipients" = [for d in var.ses_allowed_recipient_domains : "*@${d}"]
      }
    } : {}
  )
}

# -----------------------------------------------------------------------------
# ECS CLUSTER
# -----------------------------------------------------------------------------

resource "aws_ecs_cluster" "this" {
  name = var.cluster_name

  setting {
    name  = "containerInsights"
    value = var.enable_container_insights ? "enabled" : "disabled"
  }

  tags = local.common_tags
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name = aws_ecs_cluster.this.name

  capacity_providers = var.capacity_providers

  default_capacity_provider_strategy {
    base              = 1
    weight            = 100
    capacity_provider = var.default_capacity_provider
  }
}

# -----------------------------------------------------------------------------
# CLOUDWATCH LOG GROUP
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/ecs/${var.cluster_name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn != "" ? var.kms_key_arn : null

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# TASK EXECUTION ROLE (for ECS agent to pull images, push logs)
# -----------------------------------------------------------------------------

resource "aws_iam_role" "task_execution" {
  name = "${local.name_prefix}-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Additional policy for Secrets Manager and KMS access
resource "aws_iam_role_policy" "task_execution_secrets" {
  name = "${local.name_prefix}-task-execution-secrets"
  role = aws_iam_role.task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = concat(
          ["arn:aws:secretsmanager:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:secret:${var.cluster_name}/*"],
          var.secret_arns
        )
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "secretsmanager.${data.aws_region.current.id}.amazonaws.com"
          }
        }
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# TASK ROLE (for application code to access AWS services)
# -----------------------------------------------------------------------------

resource "aws_iam_role" "task" {
  name = "${local.name_prefix}-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  tags = local.common_tags
}

# Base policy for task role (CloudWatch logs + ECS Exec via SSM + S3)
resource "aws_iam_role_policy" "task_base" {
  name = "${local.name_prefix}-task-base"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Effect = "Allow"
          Action = [
            "logs:CreateLogStream",
            "logs:PutLogEvents"
          ]
          Resource = "${aws_cloudwatch_log_group.this.arn}:*"
        },
        {
          Effect = "Allow"
          Action = [
            "ssmmessages:CreateControlChannel",
            "ssmmessages:CreateDataChannel",
            "ssmmessages:OpenControlChannel",
            "ssmmessages:OpenDataChannel"
          ]
          Resource = "*"
        }
      ],
      length(var.s3_bucket_arns) > 0 ? [
        {
          Effect = "Allow"
          Action = [
            "s3:GetObject",
            "s3:PutObject",
            "s3:DeleteObject",
            "s3:ListBucket"
          ]
          Resource = flatten([
            for arn in var.s3_bucket_arns : [arn, "${arn}/*"]
          ])
        }
      ] : [],
      length(var.secret_arns) > 0 ? [
        {
          Effect = "Allow"
          Action = [
            "secretsmanager:GetSecretValue"
          ]
          Resource = var.secret_arns
        }
      ] : [],
      var.enable_ses_access ? [
        merge(
          {
            Sid    = "SendEmailViaSes"
            Effect = "Allow"
            Action = [
              "ses:SendEmail",
              "ses:SendRawEmail"
            ]
            # SESv2 SendEmail authorises against BOTH the sending identity and
            # the configuration set when one is in play, so both ARNs are listed.
            # Falls back to "*" only while they are unset (an env with no
            # app_domain has no identity to scope to).
            Resource = length(local.ses_resource_arns) > 0 ? local.ses_resource_arns : ["*"]
          },
          length(local.ses_conditions) > 0 ? { Condition = local.ses_conditions } : {}
        )
      ] : [],
      var.enable_sns_publish ? [
        {
          Sid    = "PublishToSnsTopics"
          Effect = "Allow"
          Action = [
            "sns:Publish"
          ]
          Resource = length(var.sns_topic_arns) > 0 ? var.sns_topic_arns : ["arn:aws:sns:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:*"]
        }
      ] : [],
      # SMS goes through AWS End User Messaging (sms-voice), NOT sns:Publish.
      #
      # The origination identity is Openn's AU-registered sender ID, owned by
      # the Openn production account and shared to this one via AWS RAM. That
      # avoids a second sender-ID registration (~2-3 weeks of carrier approval)
      # and — more importantly — keeps ONE opt-out list across both products,
      # which a separate registration would have split.
      #
      # A shared origination identity can only be used through the v2 API
      # (sms-voice:SendTextMessage, referencing the full ARN). sns:Publish
      # cannot reference another account's sender ID at all, which is why the
      # app moved off it.
      #
      # Note this is strictly TIGHTER than the sns:Publish grant it replaces:
      # SMS via sns:Publish has no topic ARN to authorise against and therefore
      # required Resource "*", which silently superseded the topic-scoped
      # statement above. Here the grant is pinned to the one shared sender ID.
      var.enable_sns_sms && var.sms_origination_identity_arn != "" ? [
        {
          Sid    = "SendSmsViaSharedSenderId"
          Effect = "Allow"
          Action = [
            "sms-voice:SendTextMessage"
          ]
          Resource = [
            var.sms_origination_identity_arn,
            # SendTextMessage authorises against the destination-country
            # "context" resource as well as the origination identity, so the
            # phone-number-shaped ARN in THIS account must be allowed too.
            "arn:aws:sms-voice:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:phone-number/*",
          ]
        }
      ] : []
    )
  })

  # Fail the PLAN — not a code review — if an environment ever has SES
  # production access without a recipient allowlist. In the SES sandbox the
  # allowlist is redundant (sends are limited to verified addresses), so qa
  # runs with it empty on purpose. The moment production access is granted,
  # that redundancy disappears and an empty list means the app may email
  # anyone, with the bounces counting against account-wide sender reputation.
  #
  # PROD IS THE LEGITIMATE EXCEPTION. Production sends to arbitrary customer
  # addresses, so an empty allowlist there is the INTENDED state, not an
  # oversight. Without an escape hatch this guard would force prod to either
  # invent a fake allowlist or leave ses_production_access = false — i.e. lie
  # about the account's status — both of which make the config less truthful
  # than no guard at all.
  #
  # So unrestricted sending must be declared EXPLICITLY rather than reached by
  # leaving a field blank. That keeps the failure mode "someone forgot the
  # allowlist" loud, while letting prod say what it means.
  lifecycle {
    precondition {
      condition = !(
        var.ses_production_access
        && length(var.ses_allowed_recipient_domains) == 0
        && !var.ses_allow_unrestricted_recipients
      )
      error_message = "ses_production_access is true but ses_allowed_recipient_domains is empty. Once the account leaves the SES sandbox nothing restricts who this environment can email, and bounces damage account-wide sender reputation. For non-prod set ses_allowed_recipient_domains (e.g. [\"openn.com\"]). For prod, where sending to arbitrary customer addresses is intended, set ses_allow_unrestricted_recipients = true to declare that explicitly."
    }
  }
}

# -----------------------------------------------------------------------------
# SECURITY GROUP FOR ECS TASKS
# -----------------------------------------------------------------------------

resource "aws_security_group" "tasks" {
  name        = "${local.name_prefix}-tasks-sg"
  description = "Security group for ECS Fargate tasks"
  vpc_id      = var.vpc_id

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-tasks-sg"
  })
}

resource "aws_vpc_security_group_ingress_rule" "tasks_cidr" {
  for_each = toset(var.allowed_ingress_cidrs)

  security_group_id = aws_security_group.tasks.id
  description       = "Allow inbound from CIDR on app port"
  from_port         = var.container_port
  to_port           = var.container_port
  ip_protocol       = "tcp"
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_ingress_rule" "tasks_sg" {
  count = length(var.allowed_ingress_security_group_ids)

  security_group_id            = aws_security_group.tasks.id
  description                  = "Allow inbound from ALB/upstream SG"
  from_port                    = var.container_port
  to_port                      = var.container_port
  ip_protocol                  = "tcp"
  referenced_security_group_id = var.allowed_ingress_security_group_ids[count.index]
}

# -----------------------------------------------------------------------------
# SERVICE DISCOVERY NAMESPACE (optional but useful)
# -----------------------------------------------------------------------------

resource "aws_service_discovery_private_dns_namespace" "this" {
  name        = "${var.cluster_name}.local"
  description = "Service discovery namespace for ${var.cluster_name}"
  vpc         = var.vpc_id

  tags = local.common_tags
}
