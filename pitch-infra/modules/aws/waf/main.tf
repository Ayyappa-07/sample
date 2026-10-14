################################################################################
# AWS WAFv2 Web ACL — Regional (ALB)
################################################################################

resource "aws_wafv2_web_acl" "this" {
  name        = "${var.project_name}-waf"
  description = "WAF Web ACL for ${var.project_name} ALB"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  # --------------------------------------------------------------------------
  # AWS Managed Rules — Common Rule Set (XSS, SQLi, etc.)
  # --------------------------------------------------------------------------
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 10

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"

        rule_action_override {
          name = "SizeRestrictions_BODY"

          action_to_use {
            count {}
          }
        }

        rule_action_override {
          name = "EC2MetaDataSSRF_COOKIE"

          action_to_use {
            count {}
          }
        }
      }
    }


    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-common-rules"
      sampled_requests_enabled   = true
    }
  }

  # --------------------------------------------------------------------------
  # AWS Managed Rules — Known Bad Inputs
  # --------------------------------------------------------------------------
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 20

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  # --------------------------------------------------------------------------
  # AWS Managed Rules — Amazon IP Reputation List
  # --------------------------------------------------------------------------
  rule {
    name     = "AWSManagedRulesAmazonIpReputationList"
    priority = 30

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-ip-reputation"
      sampled_requests_enabled   = true
    }
  }

  # --------------------------------------------------------------------------
  # Rate Limiting Rule
  # --------------------------------------------------------------------------
  rule {
    name     = "RateLimitRule"
    priority = 40

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.rate_limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  # --------------------------------------------------------------------------
  # Geo Restriction Rule (optional)
  # --------------------------------------------------------------------------
  dynamic "rule" {
    for_each = var.enable_geo_restriction ? [1] : []

    content {
      name     = "GeoRestrictionRule"
      priority = 50

      dynamic "action" {
        for_each = upper(var.geo_rule_action) == "COUNT" ? [1] : []

        content {
          count {}
        }
      }

      dynamic "action" {
        for_each = upper(var.geo_rule_action) == "BLOCK" ? [1] : []

        content {
          block {}
        }
      }

      statement {
        not_statement {
          statement {
            geo_match_statement {
              country_codes = var.allowed_country_codes
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${var.project_name}-geo-restriction"
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project_name}-waf"
    sampled_requests_enabled   = true
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-waf"
  })
}

################################################################################
# WAF Association with ALB
################################################################################

resource "aws_wafv2_web_acl_association" "this" {
  resource_arn = var.alb_arn
  web_acl_arn  = aws_wafv2_web_acl.this.arn
}

################################################################################
# CloudWatch Log Group for WAF Logging
################################################################################

resource "aws_cloudwatch_log_group" "waf" {
  # WAF logging requires the log group name to start with "aws-waf-logs-"
  name              = "aws-waf-logs-${var.project_name}"
  retention_in_days = var.log_retention_days

  tags = merge(var.tags, {
    Name = "aws-waf-logs-${var.project_name}"
  })
}

################################################################################
# WAF Logging Configuration
################################################################################

resource "aws_wafv2_web_acl_logging_configuration" "this" {
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]
  resource_arn            = aws_wafv2_web_acl.this.arn
}
