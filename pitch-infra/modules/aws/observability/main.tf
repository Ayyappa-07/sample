# =============================================================================
# AWS OBSERVABILITY MODULE
# =============================================================================
# CloudWatch alarms, SNS topics, and dashboards for SOC 2 compliance
#
# SOC 2 Controls: CC7.2 (monitoring), CC7.3 (alerting), CC7.4 (incident response)
# GDPR Article 33: Breach notification (alerting enables timely response)
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

check "alarm_subscribers_configured" {
  assert {
    condition     = !(var.enable_security_alarms || var.enable_cost_alarms) || length(var.alarm_email_endpoints) > 0
    error_message = "Alarms are enabled but alarm_email_endpoints is empty - notifications will reach no one."
  }
}

locals {
  name_prefix = var.project_name
  account_id  = data.aws_caller_identity.current.account_id
  region      = data.aws_region.current.id

  common_tags = merge(var.tags, {
    Module = "aws/observability"
  })
}

# -----------------------------------------------------------------------------
# SYNTHETICS CANARY ARTIFACTS
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "canary_artifacts" {
  count  = var.enable_synthetics_monitoring ? 1 : 0
  bucket = "${local.name_prefix}-canary-artifacts-${local.account_id}"

  tags = merge(local.common_tags, {
    Purpose = "synthetics-canary-artifacts"
  })
}

resource "aws_s3_bucket_versioning" "canary_artifacts" {
  count  = var.enable_synthetics_monitoring ? 1 : 0
  bucket = aws_s3_bucket.canary_artifacts[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "canary_artifacts" {
  count  = var.enable_synthetics_monitoring ? 1 : 0
  bucket = aws_s3_bucket.canary_artifacts[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "canary_artifacts" {
  count  = var.enable_synthetics_monitoring ? 1 : 0
  bucket = aws_s3_bucket.canary_artifacts[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "canary_artifacts" {
  count  = var.enable_synthetics_monitoring ? 1 : 0
  bucket = aws_s3_bucket.canary_artifacts[0].id

  rule {
    id     = "expire-canary-artifacts"
    status = "Enabled"

    filter {}

    expiration {
      days = 30
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# -----------------------------------------------------------------------------
# SYNTHETICS CANARY IAM ROLE
# -----------------------------------------------------------------------------

resource "aws_iam_role" "synthetics_canary" {
  count = var.enable_synthetics_monitoring ? 1 : 0
  name  = "${local.name_prefix}-synthetics-canary"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "synthetics_canary_basic_execution" {
  count      = var.enable_synthetics_monitoring ? 1 : 0
  role       = aws_iam_role.synthetics_canary[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "synthetics_canary" {
  count = var.enable_synthetics_monitoring ? 1 : 0
  name  = "${local.name_prefix}-synthetics-canary"
  role  = aws_iam_role.synthetics_canary[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetBucketLocation"
        ]
        Resource = [
          aws_s3_bucket.canary_artifacts[0].arn,
          "${aws_s3_bucket.canary_artifacts[0].arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ListAllMyBuckets"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData"
        ]
        Resource = "*"
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# SYNTHETICS CANARY PACKAGES
# -----------------------------------------------------------------------------

data "archive_file" "liveness" {
  count = var.enable_synthetics_monitoring ? 1 : 0

  type        = "zip"
  output_path = "${path.root}/.terraform/${local.name_prefix}-liveness.zip"

  source {
    content = templatefile("${path.module}/canary/liveness.js.tftpl", {
      health_url = "${var.canary_base_url}/api/health"
    })
    filename = "nodejs/node_modules/liveness.js"
  }
}

resource "aws_s3_object" "liveness" {
  count = var.enable_synthetics_monitoring ? 1 : 0

  bucket      = aws_s3_bucket.canary_artifacts[0].id
  key         = "source/liveness.zip"
  source      = data.archive_file.liveness[0].output_path
  source_hash = data.archive_file.liveness[0].output_base64sha256
}

data "archive_file" "readiness" {
  count = var.enable_synthetics_monitoring ? 1 : 0

  type        = "zip"
  output_path = "${path.root}/.terraform/${local.name_prefix}-readiness.zip"

  source {
    content = templatefile("${path.module}/canary/readiness.js.tftpl", {
      ready_url = "${var.canary_base_url}/api/health/ready"
    })
    filename = "nodejs/node_modules/readiness.js"
  }
}

resource "aws_s3_object" "readiness" {
  count = var.enable_synthetics_monitoring ? 1 : 0

  bucket      = aws_s3_bucket.canary_artifacts[0].id
  key         = "source/readiness.zip"
  source      = data.archive_file.readiness[0].output_path
  source_hash = data.archive_file.readiness[0].output_base64sha256
}

# -----------------------------------------------------------------------------
# SYNTHETICS CANARIES
# -----------------------------------------------------------------------------

resource "aws_synthetics_canary" "liveness" {
  count = var.enable_synthetics_monitoring ? 1 : 0

  name                 = "${local.name_prefix}-liveness"
  artifact_s3_location = "s3://${aws_s3_bucket.canary_artifacts[0].bucket}/liveness/"
  execution_role_arn   = aws_iam_role.synthetics_canary[0].arn

  depends_on = [
    aws_iam_role_policy.synthetics_canary,
    aws_iam_role_policy_attachment.synthetics_canary_basic_execution
  ]

  handler                  = "liveness.handler"
  runtime_version          = "syn-nodejs-puppeteer-9.1"
  start_canary             = true
  delete_lambda            = true
  success_retention_period = 3
  failure_retention_period = 14
  s3_bucket                = aws_s3_bucket.canary_artifacts[0].id
  s3_key                   = aws_s3_object.liveness[0].key
  s3_version               = aws_s3_object.liveness[0].version_id

  schedule {
    expression = "rate(1 minute)"
  }

  tags = local.common_tags
}

resource "aws_synthetics_canary" "readiness" {
  count = var.enable_synthetics_monitoring ? 1 : 0

  name                 = "${local.name_prefix}-ready"
  artifact_s3_location = "s3://${aws_s3_bucket.canary_artifacts[0].bucket}/readiness/"
  execution_role_arn   = aws_iam_role.synthetics_canary[0].arn

  depends_on = [
    aws_iam_role_policy.synthetics_canary,
    aws_iam_role_policy_attachment.synthetics_canary_basic_execution
  ]
  handler                  = "readiness.handler"
  runtime_version          = "syn-nodejs-puppeteer-9.1"
  start_canary             = true
  delete_lambda            = true
  success_retention_period = 3
  failure_retention_period = 14
  s3_bucket                = aws_s3_bucket.canary_artifacts[0].id
  s3_key                   = aws_s3_object.readiness[0].key
  s3_version               = aws_s3_object.readiness[0].version_id

  schedule {
    expression = "rate(5 minutes)"
  }

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# SYNTHETICS CANARY ALARMS
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "liveness_failed" {
  count = var.enable_synthetics_monitoring ? 1 : 0

  alarm_name          = "${local.name_prefix}-health-check-failed"
  alarm_description   = "GET /api/health returned non-200 or timed out for two consecutive 1-minute periods. The app may be down — check ECS service events and logs."
  namespace           = "CloudWatchSynthetics"
  metric_name         = "SuccessPercent"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 2
  threshold           = 100
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  dimensions = {
    CanaryName = aws_synthetics_canary.liveness[0].name
  }

  alarm_actions = [aws_sns_topic.operational_alerts.arn]
  ok_actions    = [aws_sns_topic.operational_alerts.arn]

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "readiness_failed" {
  count = var.enable_synthetics_monitoring ? 1 : 0

  alarm_name          = "${local.name_prefix}-dependency-unhealthy"
  alarm_description   = "GET /api/health/ready returned 503 — the database or a critical dependency is unhealthy. Inspect the response body for the failing check. Note: Redis degradation does not flip readiness to 503; see pitchai-redis-errors for Redis health."
  namespace           = "CloudWatchSynthetics"
  metric_name         = "SuccessPercent"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  threshold           = 100
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  dimensions = {
    CanaryName = aws_synthetics_canary.readiness[0].name
  }

  alarm_actions = [aws_sns_topic.operational_alerts.arn]
  ok_actions    = [aws_sns_topic.operational_alerts.arn]

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# SNS TOPICS FOR ALERTING
# -----------------------------------------------------------------------------

resource "aws_sns_topic" "security_alerts" {
  name = "${local.name_prefix}-security-alerts"

  tags = merge(local.common_tags, {
    AlertType = "security"
  })
}

resource "aws_sns_topic" "operational_alerts" {
  name = "${local.name_prefix}-operational-alerts"

  tags = merge(local.common_tags, {
    AlertType = "operational"
  })
}

resource "aws_sns_topic_policy" "security_alerts" {
  arn = aws_sns_topic.security_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudWatchAlarms"
        Effect = "Allow"
        Principal = {
          Service = "cloudwatch.amazonaws.com"
        }
        Action   = "sns:Publish"
        Resource = aws_sns_topic.security_alerts.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = local.account_id
          }
        }
      },
      {
        Sid    = "AllowEventBridge"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action   = "sns:Publish"
        Resource = aws_sns_topic.security_alerts.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = local.account_id
          }
        }
      }
    ]
  })
}

# Email subscriptions
resource "aws_sns_topic_subscription" "security_email" {
  for_each = toset(var.alarm_email_endpoints)

  topic_arn = aws_sns_topic.security_alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_sns_topic_subscription" "operational_email" {
  for_each = toset(var.alarm_email_endpoints)

  topic_arn = aws_sns_topic.operational_alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

# -----------------------------------------------------------------------------
# CLOUDTRAIL METRIC FILTERS (feed the security alarms below)
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_metric_filter" "root_login" {
  count = var.enable_security_alarms && var.cloudtrail_log_group_name != "" ? 1 : 0

  name           = "${var.project_name}-root-login"
  log_group_name = var.cloudtrail_log_group_name
  pattern        = "{ $.userIdentity.type = \"Root\" && $.userIdentity.invokedBy NOT EXISTS && $.eventType != \"AwsServiceEvent\" }"

  metric_transformation {
    name      = "RootLogin"
    namespace = "${var.project_name}/Security"
    value     = "1"
  }
}

resource "aws_cloudwatch_log_metric_filter" "unauthorized_api_calls" {
  count = var.enable_security_alarms && var.cloudtrail_log_group_name != "" ? 1 : 0

  name           = "${var.project_name}-unauthorized-api-calls"
  log_group_name = var.cloudtrail_log_group_name
  pattern        = "{ ($.errorCode = \"*UnauthorizedOperation\") || ($.errorCode = \"AccessDenied*\") }"

  metric_transformation {
    name      = "UnauthorizedAPICalls"
    namespace = "${var.project_name}/Security"
    value     = "1"
  }
}

resource "aws_cloudwatch_log_metric_filter" "console_login_failures" {
  count = var.enable_security_alarms && var.cloudtrail_log_group_name != "" ? 1 : 0

  name           = "${var.project_name}-console-login-failures"
  log_group_name = var.cloudtrail_log_group_name
  pattern        = "{ ($.eventName = \"ConsoleLogin\") && ($.errorMessage = \"Failed authentication\") }"

  metric_transformation {
    name      = "ConsoleLoginFailures"
    namespace = "${var.project_name}/Security"
    value     = "1"
  }
}

# -----------------------------------------------------------------------------
# SECURITY ALARMS (SOC 2 CC7.2, CC7.3)
# -----------------------------------------------------------------------------

# Root account usage alarm
resource "aws_cloudwatch_metric_alarm" "root_account_usage" {
  count = var.enable_security_alarms && var.cloudtrail_log_group_name != "" ? 1 : 0

  alarm_name          = "${local.name_prefix}-root-account-usage"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "RootLogin"
  namespace           = "${var.project_name}/Security"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "Root account was used - investigate immediately"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.security_alerts.arn]
  ok_actions    = [aws_sns_topic.security_alerts.arn]

  tags = local.common_tags
}

# Unauthorized API calls alarm
resource "aws_cloudwatch_metric_alarm" "unauthorized_api_calls" {
  count = var.enable_security_alarms && var.cloudtrail_log_group_name != "" ? 1 : 0

  alarm_name          = "${local.name_prefix}-unauthorized-api-calls"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "UnauthorizedAPICalls"
  namespace           = "${var.project_name}/Security"
  period              = 300
  statistic           = "Sum"
  threshold           = 10
  alarm_description   = "High number of unauthorized API calls detected"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.security_alerts.arn]
  ok_actions    = [aws_sns_topic.security_alerts.arn]

  tags = local.common_tags
}

# Console login failures alarm
resource "aws_cloudwatch_metric_alarm" "console_login_failures" {
  count = var.enable_security_alarms && var.cloudtrail_log_group_name != "" ? 1 : 0

  alarm_name          = "${local.name_prefix}-console-login-failures"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "ConsoleLoginFailures"
  namespace           = "${var.project_name}/Security"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "Multiple console login failures detected - possible brute force"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.security_alerts.arn]
  ok_actions    = [aws_sns_topic.security_alerts.arn]

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# ECS ALARMS
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "ecs_cpu_high" {
  count = var.ecs_cluster_name != "" ? 1 : 0

  alarm_name          = "${local.name_prefix}-ecs-cpu-high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "ECS cluster CPU utilization is high"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ecs_service_name
  }

  alarm_actions = [aws_sns_topic.operational_alerts.arn]
  ok_actions    = [aws_sns_topic.operational_alerts.arn]

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "ecs_memory_high" {
  count = var.ecs_cluster_name != "" ? 1 : 0

  alarm_name          = "${local.name_prefix}-ecs-memory-high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 3
  metric_name         = "MemoryUtilization"
  namespace           = "AWS/ECS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "ECS cluster memory utilization is high"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ecs_service_name
  }

  alarm_actions = [aws_sns_topic.operational_alerts.arn]
  ok_actions    = [aws_sns_topic.operational_alerts.arn]

  tags = local.common_tags
}

resource "aws_cloudwatch_log_metric_filter" "redis_errors" {
  count = var.environment == "prod" ? 1 : 0

  name           = "${local.name_prefix}-redis-errors"
  log_group_name = var.app_log_group_name
  pattern        = "{ $.level = \"error\" && $.msg = \"Redis*\" }"

  metric_transformation {
    name          = "RedisErrorCount"
    namespace     = "PitchAI/App"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "redis_errors" {
  count = var.environment == "prod" ? 1 : 0

  alarm_name          = "${local.name_prefix}-redis-errors"
  alarm_description   = "Redis connection error detected in application logs. Check Redis connectivity and application logs."
  namespace           = "PitchAI/App"
  metric_name         = "RedisErrorCount"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.operational_alerts.arn]
  ok_actions    = [aws_sns_topic.operational_alerts.arn]

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# ALB 5XX RATE ALARM
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "alb_5xx_rate" {
  count = var.alb_arn_suffix != "" && var.alb_target_group_arn_suffix != "" ? 1 : 0

  alarm_name          = "${local.name_prefix}-alb-target-5xx-rate"
  alarm_description   = "ALB 5xx response rate exceeded ${var.alb_5xx_error_pct}% over 5 minutes. Investigate ECS task logs and /api/health/ready for root cause."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = var.alb_5xx_error_pct
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.operational_alerts.arn]
  ok_actions    = [aws_sns_topic.operational_alerts.arn]

  metric_query {
    id          = "req"
    return_data = false

    metric {
      metric_name = "RequestCount"
      namespace   = "AWS/ApplicationELB"
      period      = 300
      stat        = "Sum"

      dimensions = {
        LoadBalancer = var.alb_arn_suffix
        TargetGroup  = var.alb_target_group_arn_suffix
      }
    }
  }

  metric_query {
    id          = "e5xx"
    return_data = false

    metric {
      metric_name = "HTTPCode_Target_5XX_Count"
      namespace   = "AWS/ApplicationELB"
      period      = 300
      stat        = "Sum"

      dimensions = {
        LoadBalancer = var.alb_arn_suffix
        TargetGroup  = var.alb_target_group_arn_suffix
      }
    }
  }

  metric_query {
    id          = "pct"
    expression  = "IF(req >= 20, (e5xx / req) * 100, 0)"
    label       = "5xx Response Rate (%)"
    return_data = true
  }

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "alb_target_5xx" {
  count = var.alb_arn_suffix != "" && var.alb_target_group_arn_suffix != "" ? 1 : 0

  alarm_name          = "${local.name_prefix}-alb-target-5xx"
  alarm_description   = "Application returned 5 or more 5xx responses in at least 2 of 6 five-minute periods. Investigate ECS task logs and application errors."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 6
  datapoints_to_alarm = 2
  threshold           = 5
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.operational_alerts.arn]
  ok_actions    = [aws_sns_topic.operational_alerts.arn]

  metric_name = "HTTPCode_Target_5XX_Count"
  namespace   = "AWS/ApplicationELB"
  period      = 300
  statistic   = "Sum"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = var.alb_target_group_arn_suffix
  }

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# COST ALARMS
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "billing_alarm" {
  count = var.enable_cost_alarms && local.region == "us-east-1" ? 1 : 0

  alarm_name          = "${local.name_prefix}-billing-alarm"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "EstimatedCharges"
  namespace           = "AWS/Billing"
  period              = 21600
  statistic           = "Maximum"
  threshold           = var.monthly_budget_usd * 0.8
  alarm_description   = "AWS charges have exceeded 80% of monthly budget (only works in us-east-1)"
  treat_missing_data  = "notBreaching"

  dimensions = {
    Currency = "USD"
  }

  alarm_actions = [aws_sns_topic.operational_alerts.arn]
  ok_actions    = [aws_sns_topic.operational_alerts.arn]

  tags = local.common_tags
}

# SMS Spend Alarm (70% of monthly budget)

resource "aws_cloudwatch_metric_alarm" "sms_spend_warning" {
  count = var.enable_sms ? 1 : 0

  alarm_name          = "${local.name_prefix}-sms-spend-warning"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "TextMessageMonthlySpend"
  namespace           = "AWS/SMSVoice"
  period              = 86400
  statistic           = "Maximum"
  threshold           = var.sms_monthly_spend_limit_usd * 0.7
  alarm_description   = "SMS spend has reached 70% of the ${var.sms_monthly_spend_limit_usd} monthly limit"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.operational_alerts.arn]
  ok_actions    = [aws_sns_topic.operational_alerts.arn]
  tags          = local.common_tags
}

# -----------------------------------------------------------------------------
# CLOUDWATCH DASHBOARD
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "main" {
  count = var.create_dashboard ? 1 : 0

  dashboard_name = "${local.name_prefix}-security-operations"

  dashboard_body = jsonencode({
    widgets = concat(
      # Security Section
      [
        {
          type   = "text"
          x      = 0
          y      = 0
          width  = 24
          height = 1
          properties = {
            markdown = "# Security Monitoring Dashboard"
          }
        }
      ],
      # ECS Metrics (if cluster provided)
      var.ecs_cluster_name != "" ? [
        {
          type   = "metric"
          x      = 0
          y      = 1
          width  = 12
          height = 6
          properties = {
            metrics = [
              ["AWS/ECS", "CPUUtilization", "ClusterName", var.ecs_cluster_name],
              [".", "MemoryUtilization", ".", "."]
            ]
            view    = "timeSeries"
            stacked = false
            region  = local.region
            title   = "ECS Cluster Utilization"
            period  = 300
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 1
          width  = 12
          height = 6
          properties = {
            metrics = [
              ["ECS/ContainerInsights", "RunningTaskCount", "ClusterName", var.ecs_cluster_name],
              [".", "PendingTaskCount", ".", "."]
            ]
            view    = "timeSeries"
            stacked = false
            region  = local.region
            title   = "ECS Task Counts"
            period  = 300
          }
        }
      ] : [],
      # Security Metrics
      var.cloudtrail_log_group_name != "" ? [
        {
          type   = "metric"
          x      = 0
          y      = 7
          width  = 8
          height = 6
          properties = {
            metrics = [
              ["${var.project_name}/Security", "UnauthorizedAPICalls"]
            ]
            view   = "timeSeries"
            region = local.region
            title  = "Unauthorized API Calls"
            period = 300
          }
        },
        {
          type   = "metric"
          x      = 8
          y      = 7
          width  = 8
          height = 6
          properties = {
            metrics = [
              ["${var.project_name}/Security", "ConsoleLoginFailures"]
            ]
            view   = "timeSeries"
            region = local.region
            title  = "Console Login Failures"
            period = 300
          }
        },
        {
          type   = "metric"
          x      = 16
          y      = 7
          width  = 8
          height = 6
          properties = {
            metrics = [
              ["${var.project_name}/Security", "RootLogin"]
            ]
            view   = "timeSeries"
            region = local.region
            title  = "Root Account Usage"
            period = 300
          }
        }
      ] : [],
      # Billing
      var.enable_cost_alarms ? [
        {
          type   = "metric"
          x      = 0
          y      = 13
          width  = 12
          height = 6
          properties = {
            metrics = [
              ["AWS/Billing", "EstimatedCharges", "Currency", "USD"]
            ]
            view   = "timeSeries"
            region = "us-east-1"
            title  = "Estimated Charges (USD)"
            period = 21600
          }
        }
      ] : []
    )
  })
}
