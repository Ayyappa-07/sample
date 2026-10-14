terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  backend "s3" {}
}

provider "aws" {
  region = var.region

  dynamic "assume_role" {
    for_each = var.assume_role_arn != "" ? [var.assume_role_arn] : []
    content {
      role_arn     = assume_role.value
      session_name = "terraform-${var.environment}"
    }
  }

  default_tags {
    tags = {
      Project     = "pitchai"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  dynamic "assume_role" {
    for_each = var.assume_role_arn != "" ? [var.assume_role_arn] : []
    content {
      role_arn     = assume_role.value
      session_name = "terraform-${var.environment}"
    }
  }

  default_tags {
    tags = {
      Project     = "pitchai"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

locals {
  name_prefix = "pitchai-${var.environment}"

  # Single source of truth for the SES envelope sender. Referenced by BOTH the
  # ECS task definition (SES_FROM_EMAIL) and the messaging_app_config output
  # that feeds the GitHub Actions variables — those are two paths to the same
  # setting, and a mismatch means the deployed task and the CI-set override
  # disagree on the sender address. Must stay a verified identity under
  # app_domain or SES rejects every send.
  ses_from_email = var.app_domain != "" ? "noreply@${var.app_domain}" : ""

  # Origin the app advertises as itself. Distinct from app_domain, which is tied to
  # the ACM certificates, the SES identity and the Route53 record — see variables.tf.
  app_public_url = coalesce(
    var.app_public_url != "" ? var.app_public_url : null,
    var.app_domain != "" ? "https://${var.app_domain}" : null,
    "http://${aws_lb.this.dns_name}",
  )

  tags = merge(var.tags, {
    Environment = var.environment
  })
}

# =============================================================================
# NETWORKING
# =============================================================================

module "networking" {
  source = "./modules/aws/networking"

  vpc_name                      = "${local.name_prefix}-vpc"
  vpc_cidr                      = var.vpc_cidr
  region                        = var.region
  public_subnets                = var.public_subnets
  private_subnets               = var.private_subnets
  enable_nat_gateway            = true
  single_nat_gateway            = var.environment != "prod"
  enable_flow_logs              = true
  flow_logs_retention_days      = var.environment == "prod" ? 90 : 30
  enable_vpc_endpoints          = var.enable_vpc_endpoints
  enable_optional_vpc_endpoints = var.enable_optional_vpc_endpoints
  tags                          = local.tags
}

# =============================================================================
# ECS CLUSTER
# =============================================================================

module "ecs" {
  source = "./modules/aws/ecs"

  cluster_name = "${local.name_prefix}-cluster"
  vpc_id       = module.networking.vpc_id
  subnet_ids   = module.networking.private_subnet_ids

  container_port                     = var.container_port
  enable_container_insights          = true
  log_retention_days                 = var.environment == "prod" ? 90 : 30
  capacity_providers                 = ["FARGATE", "FARGATE_SPOT"]
  default_capacity_provider          = var.environment == "prod" ? "FARGATE" : "FARGATE_SPOT"
  allowed_ingress_cidrs              = [var.vpc_cidr]
  allowed_ingress_security_group_ids = [aws_security_group.alb.id]
  secret_arns = concat(
    [module.rds.master_user_secret_arn],
    values(module.secrets.secret_arns),
    [module.elasticache.auth_token_secret_arn]
  )
  s3_bucket_arns     = [module.s3.bucket_arn]
  enable_ses_access  = true
  enable_sns_publish = true
  sns_topic_arns     = []

  # SMS: sendSms() publishes to a bare phone number, which IAM can only
  # authorise via Resource "*" — the topic-scoped grant above does not cover it.
  enable_sns_sms               = var.enable_sms
  sms_origination_identity_arn = var.sms_origination_identity_arn

  # Scope SES sending to this env's own identity + configuration set.
  ses_identity_arn                  = var.app_domain != "" ? aws_ses_domain_identity.this[0].arn : ""
  ses_configuration_set_arn         = var.app_domain != "" ? aws_sesv2_configuration_set.this[0].arn : ""
  ses_from_domain                   = var.app_domain
  ses_allowed_recipient_domains     = var.ses_allowed_recipient_domains
  ses_production_access             = var.ses_production_access
  ses_allow_unrestricted_recipients = var.ses_allow_unrestricted_recipients

  tags = local.tags
}

# =============================================================================
# ECR
# =============================================================================

module "ecr" {
  source = "./modules/aws/ecr"

  repository_name      = var.environment == "prod" ? "pitchai-app-prod" : "pitchai-app"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false
  image_count_keep     = var.environment == "prod" ? 20 : 5
  tags                 = local.tags
}

# =============================================================================
# RDS POSTGRESQL
# =============================================================================
# RDS-managed master password rotation is intentionally disabled for now.
#
# ECS reads DATABASE_PASSWORD from the RDS-managed Secrets Manager secret only
# when a task starts. If RDS rotates the password while existing ECS tasks are
# running, those tasks keep the old password and database authentication fails.
#
# Rotation must not be re-enabled until the RotationSucceeded ->
# EventBridge -> Lambda -> ECS force-new-deployment path is deployed and
# verified. After verification, rotation can be reconsidered.
module "rds" {
  source = "./modules/aws/rds"

  project_name   = local.name_prefix
  vpc_id         = module.networking.vpc_id
  subnet_ids     = module.networking.private_subnet_ids
  engine         = "postgres"
  engine_version = "17.10" # latest major available in ap-southeast-2 — greenfield DB, no legacy constraint, longest EOL runway. (AWS retires old minors; the original 16.4 pin was no longer creatable.)
  instance_class = var.rds_instance_class

  master_username             = "pitchai_admin"
  manage_master_user_password = true
  database_name               = "pitchai"
  parameter_group_family      = "postgres17"

  allocated_storage     = var.rds_allocated_storage
  max_allocated_storage = var.rds_max_allocated_storage

  multi_az            = var.environment == "prod"
  deletion_protection = var.environment == "prod"
  skip_final_snapshot = var.environment != "prod"

  allowed_cidr_blocks        = [for s in var.private_subnets : s.cidr]
  allowed_security_group_ids = [module.ecs.tasks_security_group_id]
  alarm_sns_topic_arns       = [module.observability.operational_alerts_topic_arn]

  backup_retention_period        = var.environment == "prod" ? 30 : 7
  log_retention_days             = var.environment == "prod" ? 90 : 30
  enable_performance_insights    = true
  performance_insights_retention = var.environment == "prod" ? 731 : 7
  apply_immediately              = var.environment != "prod"

  tags = local.tags
}

# =============================================================================
# ELASTICACHE REDIS
# =============================================================================

module "elasticache" {
  source = "./modules/aws/elasticache"

  project_name               = local.name_prefix
  vpc_id                     = module.networking.vpc_id
  subnet_ids                 = module.networking.private_subnet_ids
  allowed_security_group_ids = [module.ecs.tasks_security_group_id]
  node_type                  = var.redis_node_type
  num_cache_clusters         = var.environment == "prod" ? 2 : 1
  snapshot_retention_limit   = var.environment == "prod" ? 7 : 0
  alarm_sns_topic_arns       = [module.observability.operational_alerts_topic_arn]
  tags                       = local.tags
}

# =============================================================================
# S3 STORAGE
# =============================================================================

module "s3" {
  source = "./modules/aws/s3"

  bucket_name            = "${local.name_prefix}-storage"
  enable_versioning      = true
  enable_lifecycle_rules = var.environment == "prod"
  cors_allowed_origins = distinct(compact(concat(
    var.app_domain != "" ? ["https://${var.app_domain}"] : [],
    [for d in var.extra_domain_aliases : "https://${d}"],
  )))
  force_destroy = var.environment != "prod"
  tags          = local.tags
}

# =============================================================================
# S3 ACCESS LOG STORAGE
# Dedicated bucket for ALB and CloudFront access logs
# =============================================================================

resource "aws_s3_bucket" "access_logs" {
  bucket        = "${local.name_prefix}-access-logs"
  force_destroy = var.environment != "prod"

  tags = merge(local.tags, {
    Name    = "${local.name_prefix}-access-logs"
    Purpose = "ALB and CloudFront access logs"
  })
}

resource "aws_s3_bucket_ownership_controls" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    id     = "access-log-retention"
    status = "Enabled"

    filter {}


    expiration {
      days = 90
    }
  }
}

resource "aws_s3_bucket_policy" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowELBLogDelivery"
        Effect = "Allow"
        Principal = {
          AWS     = data.aws_elb_service_account.main.arn
          Service = "logdelivery.elasticloadbalancing.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.access_logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
      },
      {
        Sid    = "AllowCloudFrontLogDelivery"
        Effect = "Allow"

        Principal = {
          Service = "delivery.logs.amazonaws.com"
        }

        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.access_logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/CloudFront/*"

        Condition = {
          StringEquals = {

            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }

          ArnLike = {
            "aws:SourceArn" = "arn:aws:logs:us-east-1:${data.aws_caller_identity.current.account_id}:delivery-source:*"
          }
        }
      },

      {
        Sid    = "AllowCloudFrontLogDeliveryBucketAccess"
        Effect = "Allow"

        Principal = {
          Service = "delivery.logs.amazonaws.com"
        }

        Action = [
          "s3:GetBucketAcl",
          "s3:ListBucket"
        ]

        Resource = aws_s3_bucket.access_logs.arn

        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }

          ArnLike = {
            "aws:SourceArn" = "arn:aws:logs:us-east-1:${data.aws_caller_identity.current.account_id}:delivery-source:*"
          }
        }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.access_logs.arn,
          "${aws_s3_bucket.access_logs.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

# =============================================================================
# SECRETS MANAGER (API keys)
# =============================================================================

module "secrets" {
  source = "./modules/aws/secrets"

  project_name = local.name_prefix
  secrets = {
    "anthropic-api-key"        = { description = "Anthropic Claude API key" }
    "openai-api-key"           = { description = "OpenAI API key" }
    "browserless-api-key"      = { description = "Browserless API key" }
    "viewer-identity-secret"   = { description = "Viewer identity signing secret (>=32 chars, hard-required at boot)" }
    "cron-secret"              = { description = "Secret token for authenticating cron/scheduler requests" }
    "nextauth-secret"          = { description = "NextAuth.js session secret" }
    "openn-pitch-sync-api-key" = { description = "Openn Pitch sync API key (OPENN_PITCH_SYNC_API_KEY)" }
    "openn-app-key"            = { description = "Openn app key (OPENN_APP_KEY)" }
    "domain-client-id"         = { description = "Domain.com.au OAuth client id (agent search / onboarding)" }
    "domain-client-secret"     = { description = "Domain.com.au OAuth client secret" }
    # DATABASE_URL / REDIS_URL are assembled in docker-entrypoint.sh from the
    # DATABASE_* / REDIS_* parts (host/port/name from env, password via valueFrom
    # off the RDS-managed + ElastiCache AUTH secrets), so no standalone URL secret.
  }
  allowed_role_arns = [
    module.ecs.task_execution_role_arn,
    module.ecs.task_role_arn
  ]
  tags = local.tags
}

# =============================================================================
# ALB + HTTPS
# =============================================================================
data "aws_elb_service_account" "main" {}
data "aws_ec2_managed_prefix_list" "cloudfront_origin_facing" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "Security group for the ALB"
  vpc_id      = module.networking.vpc_id

  ingress {
    description     = "HTTPS from CloudFront"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront_origin_facing.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, {
    Name = "${local.name_prefix}-alb-sg"
  })
}

resource "aws_lb" "this" {
  name               = "${local.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = module.networking.public_subnet_ids

  idle_timeout               = 300
  drop_invalid_header_fields = true

  access_logs {
    bucket  = aws_s3_bucket.access_logs.id
    enabled = true
  }

  depends_on = [
    aws_s3_bucket_policy.access_logs
  ]


  tags = local.tags
}

resource "aws_lb_target_group" "app" {
  name                 = "${local.name_prefix}-tg"
  port                 = var.container_port
  protocol             = "HTTP"
  vpc_id               = module.networking.vpc_id
  target_type          = "ip"
  deregistration_delay = 60

  health_check {
    path                = "/api/health"
    port                = "traffic-port"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 10
    interval            = 30
    matcher             = "200"
  }

  tags = local.tags
}

# =============================================================================
# DNS (Route53) + TLS (ACM)
# =============================================================================

locals {
  create_dns        = var.app_domain != ""
  use_existing_zone = var.route53_zone_id != ""
  zone_id           = local.create_dns ? (local.use_existing_zone ? var.route53_zone_id : aws_route53_zone.this[0].zone_id) : ""
  cert_arn          = var.acm_certificate_arn != "" ? var.acm_certificate_arn : (local.create_dns ? aws_acm_certificate.this[0].arn : "")
  # HTTPS is on when we either were given a cert or will create one (app_domain set).
  # Derive from INPUTS, not from cert_arn — cert_arn references the not-yet-created
  # ACM ARN, which is unknown at plan and makes the listener `count`s unresolvable.
  https_enabled = var.acm_certificate_arn != "" || local.create_dns
}

resource "aws_route53_zone" "this" {
  count = local.create_dns && !local.use_existing_zone && var.create_dns_zone ? 1 : 0

  name    = var.app_domain
  comment = "Hosted zone for ${local.name_prefix}"

  tags = local.tags
}

resource "aws_acm_certificate" "this" {
  count = local.create_dns && var.acm_certificate_arn == "" ? 1 : 0

  domain_name       = var.app_domain
  validation_method = "DNS"

  subject_alternative_names = concat(["*.${var.app_domain}"], var.extra_domain_aliases)

  tags = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = local.create_dns && var.acm_certificate_arn == "" ? {
    for dvo in aws_acm_certificate.this[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  } : {}

  allow_overwrite = true
  name            = each.value.name
  type            = each.value.type
  zone_id         = local.zone_id
  records         = [each.value.record]
  ttl             = 60
}

resource "aws_acm_certificate_validation" "this" {
  count = local.create_dns && var.acm_certificate_arn == "" ? 1 : 0

  certificate_arn         = aws_acm_certificate.this[0].arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

# CloudFront requires ACM cert in us-east-1
resource "aws_acm_certificate" "cloudfront" {
  count    = local.create_dns && var.enable_cloudfront ? 1 : 0
  provider = aws.us_east_1

  domain_name       = var.app_domain
  validation_method = "DNS"

  subject_alternative_names = concat(
    ["*.${var.app_domain}"],
    var.extra_domain_aliases,
    [for d in var.extra_domain_aliases : "*.${d}"]
  )

  tags = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate_validation" "cloudfront" {
  count    = local.create_dns && var.enable_cloudfront ? 1 : 0
  provider = aws.us_east_1

  certificate_arn = aws_acm_certificate.cloudfront[0].arn
  validation_record_fqdns = concat(
    [for record in aws_route53_record.cert_validation : record.fqdn],
    [for record in aws_route53_record.cloudfront_cert_extra_validation : record.fqdn]
  )
}

resource "aws_route53_record" "cloudfront_cert_extra_validation" {
  for_each = local.create_dns && var.enable_cloudfront ? {
    for domain in local.all_cert_domains :
    domain => {
      for dvo in aws_acm_certificate.cloudfront[0].domain_validation_options :
      "v" => dvo
      if dvo.domain_name == domain
    }
    if !contains(keys(aws_route53_record.cert_validation), domain)
  } : {}

  allow_overwrite = true
  name            = each.value["v"].resource_record_name
  type            = each.value["v"].resource_record_type
  zone_id         = local.zone_id
  records         = [each.value["v"].resource_record_value]
  ttl             = 60
}

locals {
  cloudfront_cert_arn = var.enable_cloudfront && local.create_dns ? aws_acm_certificate.cloudfront[0].arn : ""
}
locals {
  all_cert_domains = toset(concat(
    [var.app_domain],
    ["*.${var.app_domain}"],
    var.extra_domain_aliases,
    [for d in var.extra_domain_aliases : "*.${d}"]
  ))
}

resource "aws_route53_record" "app" {
  count = local.create_dns && !var.enable_cloudfront ? 1 : 0

  zone_id = local.zone_id
  name    = var.app_domain
  type    = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}

# =============================================================================
# ALB LISTENERS
# =============================================================================

resource "aws_lb_listener" "http_forward" {
  count = !local.https_enabled ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

resource "aws_lb_listener" "http_redirect" {
  count = local.https_enabled ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  count = local.https_enabled ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = local.cert_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  depends_on = [aws_acm_certificate_validation.this]
}

# =============================================================================
# CLOUDFRONT (edge-cache Next.js static assets, offload origin)
# =============================================================================

resource "aws_cloudfront_distribution" "this" {
  count = var.enable_cloudfront ? 1 : 0

  enabled             = true
  is_ipv6_enabled     = true
  http_version        = "http2and3"
  price_class         = var.environment == "prod" ? "PriceClass_All" : "PriceClass_200"
  aliases             = var.app_domain != "" ? concat([var.app_domain], var.extra_domain_aliases) : []
  web_acl_id          = var.enable_waf ? aws_wafv2_web_acl.cloudfront[0].arn : null
  default_root_object = ""

  origin {
    domain_name = aws_lb.this.dns_name
    origin_id   = "alb"

    custom_origin_config {
      http_port                = 80
      https_port               = 443
      origin_protocol_policy   = local.https_enabled ? "https-only" : "http-only"
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_read_timeout      = 60
      origin_keepalive_timeout = 60
    }
  }

  # Static assets — long cache
  ordered_cache_behavior {
    path_pattern     = "/_next/static/*"
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "alb"
    compress         = true

    forwarded_values {
      query_string = false
      headers      = ["Host"]
      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 31536000
    default_ttl            = 31536000
    max_ttl                = 31536000
  }

  # Public folder assets
  ordered_cache_behavior {
    path_pattern     = "/favicon*"
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "alb"
    compress         = true

    forwarded_values {
      query_string = false
      headers      = ["Host"]
      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 86400
    default_ttl            = 86400
    max_ttl                = 604800
  }

  # Uploaded media proxy (PA-84) — the app streams private-bucket objects from
  # /api/public/media/* using its own AWS credentials (the bucket has no
  # public-read policy, so raw S3 URLs 403). The route is public and the key is
  # an unguessable UUID, so it is safe to edge-cache: strip cookies, ignore the
  # query string, and honour the route's own long immutable Cache-Control. This
  # keeps repeat media loads off the origin while the bucket stays private.
  ordered_cache_behavior {
    path_pattern     = "/api/public/media/*"
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "alb"
    compress         = true

    forwarded_values {
      query_string = false
      # Host must be forwarded so the ALB's ACM cert (issued for the app domain,
      # not the raw ALB DNS name) matches the SNI CloudFront presents on the
      # origin connection. Without it CloudFront sends the ALB hostname as SNI
      # and the TLS handshake fails with a 502.
      headers = ["Host"]
      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 86400
    max_ttl                = 31536000
  }

  # Default — pass through to origin (dynamic pages, API)
  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "alb"
    compress         = true

    forwarded_values {
      query_string = true
      headers      = ["Host", "Authorization", "Accept", "Accept-Language"]
      cookies {
        forward = "all"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 0
    max_ttl                = 0
  }

  viewer_certificate {
    acm_certificate_arn            = local.cloudfront_cert_arn != "" ? local.cloudfront_cert_arn : null
    cloudfront_default_certificate = local.cloudfront_cert_arn == ""
    ssl_support_method             = local.cloudfront_cert_arn != "" ? "sni-only" : null
    minimum_protocol_version       = "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  tags = local.tags
}

# =============================================================================
# CLOUDFRONT STANDARD LOGGING V2
# =============================================================================

resource "aws_cloudwatch_log_delivery_source" "cloudfront_access_logs" {
  count = var.enable_cloudfront ? 1 : 0

  provider = aws.us_east_1

  name         = "${local.name_prefix}-cloudfront-access-logs"
  log_type     = "ACCESS_LOGS"
  resource_arn = aws_cloudfront_distribution.this[0].arn
}

resource "aws_cloudwatch_log_delivery_destination" "cloudfront_access_logs" {
  count = var.enable_cloudfront ? 1 : 0

  provider = aws.us_east_1

  name          = "${local.name_prefix}-cloudfront-access-logs"
  output_format = "json"

  delivery_destination_configuration {
    destination_resource_arn = aws_s3_bucket.access_logs.arn
  }
}

resource "aws_cloudwatch_log_delivery" "cloudfront_access_logs" {
  count = var.enable_cloudfront ? 1 : 0

  provider = aws.us_east_1

  delivery_source_name     = aws_cloudwatch_log_delivery_source.cloudfront_access_logs[0].name
  delivery_destination_arn = aws_cloudwatch_log_delivery_destination.cloudfront_access_logs[0].arn

  record_fields = [
    "date",
    "time",
    "x-edge-location",
    "sc-bytes",
    "c-ip",
    "cs-method",
    "cs(Host)",
    "cs-uri-stem",
    "sc-status",
    "cs(Referer)",
    "cs(User-Agent)",
    "x-edge-result-type",
    "x-edge-request-id",
    "x-host-header",
    "cs-protocol",
    "cs-bytes",
    "time-taken",
    "x-forwarded-for",
    "ssl-protocol",
    "ssl-cipher",
    "x-edge-response-result-type",
    "cs-protocol-version",
    "fle-status",
    "fle-encrypted-fields",
    "c-port",
    "time-to-first-byte",
    "x-edge-detailed-result-type",
    "sc-content-type",
    "sc-content-len",
    "sc-range-start",
    "sc-range-end",
    "c-country",
    "cache-behavior-path-pattern"
  ]

  depends_on = [
    aws_s3_bucket_policy.access_logs
  ]
}

# WAF for CloudFront must be in us-east-1 — use a separate WAFv2 scope
resource "aws_wafv2_web_acl" "cloudfront" {
  count = var.enable_waf && var.enable_cloudfront ? 1 : 0

  provider = aws.us_east_1

  name        = "${local.name_prefix}-cloudfront-waf"
  scope       = "CLOUDFRONT"
  description = "WAF for CloudFront distribution"

  default_action {
    allow {}
  }

  rule {
    name     = "aws-managed-common"
    priority = 1
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
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-cf-common"
    }
  }

  rule {
    name     = "rate-limit"
    priority = 2
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = var.environment == "prod" ? 2000 : 5000
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-cf-rate"
    }
  }

  visibility_config {
    sampled_requests_enabled   = true
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name_prefix}-cf-waf"
  }

  tags = local.tags
}

resource "aws_cloudwatch_log_group" "cloudfront_waf" {
  count = var.enable_waf && var.enable_cloudfront ? 1 : 0

  provider          = aws.us_east_1
  name              = "aws-waf-logs-${local.name_prefix}-cloudfront"
  retention_in_days = 30

  tags = merge(local.tags, {
    Name = "aws-waf-logs-${local.name_prefix}-cloudfront"
  })
}

resource "aws_wafv2_web_acl_logging_configuration" "cloudfront" {
  count = var.enable_waf && var.enable_cloudfront ? 1 : 0

  provider = aws.us_east_1

  log_destination_configs = [
    aws_cloudwatch_log_group.cloudfront_waf[0].arn
  ]

  resource_arn = aws_wafv2_web_acl.cloudfront[0].arn
}

# Update Route53 to point at CloudFront when enabled
resource "aws_route53_record" "app_cloudfront" {
  for_each = local.create_dns && var.enable_cloudfront ? toset(
    concat([var.app_domain], var.extra_domain_aliases)
  ) : toset([])

  zone_id = local.zone_id
  name    = each.value
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.this[0].domain_name
    zone_id                = aws_cloudfront_distribution.this[0].hosted_zone_id
    evaluate_target_health = false
  }
}

moved {
  from = aws_route53_record.app_cloudfront[0]
  to   = aws_route53_record.app_cloudfront["qa.pitch.openn.com"]
}

# =============================================================================
# WAF — ALB (regional, protects ALB regardless of CloudFront)
# =============================================================================

module "waf" {
  count  = var.enable_waf ? 1 : 0
  source = "./modules/aws/waf"

  project_name           = local.name_prefix
  alb_arn                = aws_lb.this.arn
  rate_limit             = var.environment == "prod" ? 2000 : 5000
  enable_geo_restriction = var.enable_geo_restriction
  geo_rule_action        = var.geo_rule_action
  allowed_country_codes  = var.allowed_country_codes
  tags                   = local.tags
}

# =============================================================================
# ECS TASK DEFINITION — Pitch Next.js App
# =============================================================================

# =============================================================================
# Shared app env + secrets — used by BOTH the app service and the migrations
# task. post-merge.sh's seed steps import src/db/client.ts -> getConfig(), whose
# NODE_ENV=production gate hard-requires the same env the app needs, so the
# migration task must carry the full set (not just DATABASE_*). REDIS_URL /
# DATABASE_URL are assembled from the parts by the image's docker-entrypoint.sh.
# =============================================================================
locals {
  app_environment = [
    { name = "NODE_ENV", value = "production" },
    { name = "APP_ENV", value = var.environment },
    { name = "PORT", value = tostring(var.container_port) },
    { name = "DATABASE_HOST", value = module.rds.db_instance_address },
    { name = "DATABASE_PORT", value = tostring(module.rds.db_instance_port) },
    { name = "DATABASE_USER", value = "pitchai_admin" },
    { name = "DATABASE_NAME", value = "pitchai" },
    # require: valid for psql/libpq (encrypt, no verify) AND mapped to
    # rejectUnauthorized=false by the app (src/db/client.ts) + drizzle-kit
    # (drizzle.config.ts). no-verify is node-only and libpq rejects it.
    { name = "DATABASE_SSL", value = "require" },
    { name = "REDIS_HOST", value = module.elasticache.primary_endpoint_address },
    { name = "REDIS_PORT", value = tostring(module.elasticache.port) },
    { name = "REDIS_TLS", value = "true" },
    { name = "AWS_S3_BUCKET", value = module.s3.bucket_id },
    { name = "AWS_S3_REGION", value = var.region }, # app reads AWS_S3_REGION, not S3_REGION
    { name = "NEXT_PUBLIC_APP_URL", value = local.app_public_url },
    { name = "NEXTAUTH_URL", value = local.app_public_url },
    { name = "PG_POOL_MAX", value = tostring(var.pg_pool_max) },
    { name = "DOMAIN_APP", value = replace(local.app_public_url, "/^https?:///", "") },
    { name = "DOMAIN_API", value = var.domain_api },
    { name = "DOMAIN_OPENN_WEBHOOK", value = var.domain_openn_webhook },
    { name = "SES_FROM_EMAIL", value = local.ses_from_email },
    { name = "SES_CONFIGURATION_SET", value = var.app_domain != "" ? aws_sesv2_configuration_set.this[0].configuration_set_name : "" },
    # SMS origination identity (PA-111). The app reads this in
    # src/lib/integrations/sns.ts and THROWS when it is unset, which
    # sendSmsWithStatus then swallows as { ok: false } — so a missing value
    # here is a SILENT no-send, not a visible error. It must be the full ARN:
    # the identity is Openn's, shared cross-account via RAM, so a bare sender
    # ID string cannot resolve it. SNS_REGION is deliberately not set; the app
    # falls back to AWS_S3_REGION, which is already var.region.
    { name = "SNS_ORIGINATION_IDENTITY", value = var.sms_origination_identity_arn },
    # NOTE: the Openn SSO config (OPENN_SSO_* / OPENN_API_BASE_URL /
    # OPENN_GLOBAL_LOGOUT_URL / OPENN_SSO_SESSION_*) is NOT set here. It's
    # owned by the Pitch app's deploy workflow (GitHub Actions variables),
    # which injects it into the task-def env at deploy time. The ECS service
    # has ignore_changes=[task_definition], so Terraform stays out of it.
    # OPENN_PITCH_SYNC_API_KEY remains a Secrets Manager secret (below).
  ]

  app_secrets = [
    { name = "DATABASE_PASSWORD", valueFrom = "${module.rds.master_user_secret_arn}:password::" },
    { name = "REDIS_PASSWORD", valueFrom = module.elasticache.auth_token_secret_arn },
    { name = "ANTHROPIC_API_KEY", valueFrom = module.secrets.secret_arns["anthropic-api-key"] },
    { name = "AI_INTEGRATIONS_OPENAI_API_KEY", valueFrom = module.secrets.secret_arns["openai-api-key"] },
    { name = "DOMAIN_CLIENT_ID", valueFrom = module.secrets.secret_arns["domain-client-id"] },
    { name = "DOMAIN_CLIENT_SECRET", valueFrom = module.secrets.secret_arns["domain-client-secret"] },
    { name = "BROWSERLESS_API_KEY", valueFrom = module.secrets.secret_arns["browserless-api-key"] },
    { name = "VIEWER_IDENTITY_SECRET", valueFrom = module.secrets.secret_arns["viewer-identity-secret"] },
    { name = "CRON_SECRET", valueFrom = module.secrets.secret_arns["cron-secret"] },
    { name = "NEXTAUTH_SECRET", valueFrom = module.secrets.secret_arns["nextauth-secret"] },
    { name = "OPENN_PITCH_SYNC_API_KEY", valueFrom = module.secrets.secret_arns["openn-pitch-sync-api-key"] },
    { name = "OPENN_APP_KEY", valueFrom = module.secrets.secret_arns["openn-app-key"] },
  ]
}

resource "aws_ecs_task_definition" "app" {
  family                   = "${local.name_prefix}-app"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = module.ecs.task_execution_role_arn
  task_role_arn            = module.ecs.task_role_arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([
    {
      name        = "app"
      image       = var.app_image
      essential   = true
      stopTimeout = 30
      # init: reap zombies + forward signals (entrypoint exec's `next start`).
      linuxParameters = { initProcessEnabled = true }
      healthCheck = {
        # node fetch, NOT wget/curl: the runtime image (node:20-bookworm-slim)
        # ships neither — same probe as the Dockerfile's own HEALTHCHECK.
        command     = ["CMD", "node", "-e", "fetch('http://127.0.0.1:${var.container_port}/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60 # non-standalone `next start` on 0.5 vCPU boots slowly
      }
      portMappings = [
        {
          containerPort = var.container_port
          protocol      = "tcp"
        }
      ]
      environment = local.app_environment
      secrets     = local.app_secrets
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = module.ecs.log_group_name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "app"
        }
      }
    }
  ])
}

# =============================================================================
# ECS SERVICE
# =============================================================================

resource "aws_ecs_service" "app" {
  name            = "${local.name_prefix}-service"
  cluster         = module.ecs.cluster_id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.desired_count

  # Capacity — prod is on-demand only; non-prod pins ONE on-demand task and puts
  # everything above it on Spot. Fixes the repeated qa outages of 2026-07-31 and
  # 2026-08-03.
  #
  # base = 1 on FARGATE is the load-bearing part, and it is NOT interchangeable
  # with weighting. Weights only distribute tasks that ECS is already able to
  # launch; if the preferred provider cannot place, the scheduler retries that
  # provider rather than reassigning to another. We proved this live on
  # 2026-08-03: a 10:1 FARGATE_SPOT:FARGATE strategy with no base kept emitting
  # "Capacity is unavailable at this time" and never touched on-demand. Adding
  # base = 1 placed a task within seconds.
  #
  # Two failure modes, and they need different defences:
  #   * interruption — Spot reclaims a task. desired_count = 2 across three AZs
  #     covers this; the surviving task keeps serving and users see nothing.
  #   * drought — no Spot capacity for this task shape anywhere in the region.
  #     Task count and AZ spread are useless here. Only base = 1 helps.
  #
  # Cost is ~$21/mo on-demand + ~$6.50 Spot vs ~$13 for two Spot tasks. The
  # extra ~$15/mo buys a QA environment that stays reachable; the outages it
  # replaces also blocked CI, because the deploy workflow waits on
  # `aws ecs wait services-stable` and fails when tasks cannot place.
  #
  # WARNING — changing these values on an EXISTING service is not safe by
  # default. capacity_provider_strategy is ForceNew in the AWS provider unless
  # force_new_deployment is set, so an edit destroys and recreates
  # aws_ecs_service.app. On replacement Terraform rebuilds from config, where
  # `task_definition` resolves to aws_ecs_task_definition.app — still revision 18
  # with image "initial", because var.app_image defaults to that and CI registers
  # the real task definitions outside Terraform (lifecycle ignore_changes does
  # NOT apply on replace). That would point the env at an image that does not
  # exist. This block was therefore applied to the live qa service FIRST
  # (aws ecs update-service) and mirrored here afterwards, so refresh sees config
  # and reality already in agreement and plans no change.
  #
  # BEFORE CHANGING THESE VALUES AGAIN, pick one:
  #   a) set force_new_deployment = true on this resource — per review, the
  #      provider stopped treating capacity_provider_strategy as ForceNew when
  #      that flag is set (v5.59+), which makes a strategy edit an in-place
  #      swap and removes the need for the update-service-first dance. NOT
  #      enabled here because it has not been verified against 5.100 on a live
  #      service, and it also redeploys the service on any apply that touches it.
  #   b) repeat the live-first order used above.
  #   c) fix the root cause: make Terraform track the deployed image, by passing
  #      app_image at apply time or reading the live task definition via a data
  #      source. This is the only option that also makes a first apply of a NEW
  #      environment correct — today a greenfield staging/prod apply would create
  #      the service pointing at image "initial" regardless of this block.
  dynamic "capacity_provider_strategy" {
    for_each = var.environment == "prod" ? ["FARGATE"] : ["FARGATE", "FARGATE_SPOT"]
    content {
      capacity_provider = capacity_provider_strategy.value
      weight            = capacity_provider_strategy.value == "FARGATE_SPOT" ? 10 : 1
      base              = capacity_provider_strategy.value == "FARGATE" ? 1 : 0
    }
  }

  network_configuration {
    subnets          = module.networking.private_subnet_ids
    security_groups  = [module.ecs.tasks_security_group_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "app"
    container_port   = var.container_port
  }

  health_check_grace_period_seconds  = 60
  deployment_minimum_healthy_percent = var.desired_count <= 1 ? 100 : 50
  deployment_maximum_percent         = 200

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  enable_execute_command = true

  depends_on = [module.ecs, aws_lb_listener.http_forward, aws_lb_listener.http_redirect, aws_lb_listener.https]

  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }
}

# =============================================================================
# AUTOSCALING
# =============================================================================

resource "aws_appautoscaling_target" "ecs_service" {
  max_capacity       = var.max_capacity
  min_capacity       = var.desired_count
  resource_id        = "service/${module.ecs.cluster_name}/${aws_ecs_service.app.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "request_count" {
  name               = "${local.name_prefix}-request-count-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_service.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_service.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_service.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${aws_lb.this.arn_suffix}/${aws_lb_target_group.app.arn_suffix}"
    }
    target_value       = var.autoscaling_requests_per_target
    scale_in_cooldown  = 120
    scale_out_cooldown = 30
  }
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${local.name_prefix}-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_service.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_service.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_service.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 75
    scale_in_cooldown  = 180
    scale_out_cooldown = 60
  }
}

# =============================================================================
# MIGRATIONS TASK DEFINITION
# =============================================================================

resource "aws_ecs_task_definition" "migrations" {
  family                   = "${local.name_prefix}-migrations"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 512 # tsx compiles the seed graph; 256 risks OOM
  memory                   = 1024
  execution_role_arn       = module.ecs.task_execution_role_arn
  task_role_arn            = module.ecs.task_role_arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([
    {
      name      = "migrate"
      image     = var.app_image
      essential = true
      # Canonical migration mechanism = the idempotent SQL replay (psql -f over
      # src/db/migrations/*.sql, then the template seed + data migrations).
      # NOT `npm run db:migrate` (= drizzle-kit migrate), which replays the legacy
      # drizzle/ journal (0000-0006, never for prod) and collides with the db:push
      # bootstrap schema. The image is built for this path (Dockerfile keeps
      # src/+scripts/, installs psql+tsx). Runs through the entrypoint, which
      # assembles DATABASE_URL from the DATABASE_* env first.
      command = ["/app/scripts/post-merge.sh"]
      # init: reap zombies + forward signals for the entrypoint-exec'd script.
      linuxParameters = { initProcessEnabled = true }
      # Full app env+secrets: the seed steps import src/db/client.ts -> getConfig(),
      # whose NODE_ENV=production gate requires the same env the app needs.
      environment = local.app_environment
      secrets     = local.app_secrets
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = module.ecs.log_group_name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "migrations"
        }
      }
    }
  ])
}

# =============================================================================
# OBSERVABILITY
# =============================================================================

module "observability" {
  source      = "./modules/aws/observability"
  environment = var.environment

  project_name                 = local.name_prefix
  ecs_cluster_name             = module.ecs.cluster_name
  ecs_service_name             = aws_ecs_service.app.name
  app_log_group_name           = module.ecs.log_group_name
  vpc_id                       = module.networking.vpc_id
  alarm_email_endpoints        = var.alarm_email_endpoints
  enable_security_alarms       = var.environment == "prod"
  enable_cost_alarms           = var.environment == "prod"
  enable_synthetics_monitoring = var.environment == "prod"
  monthly_budget_usd           = var.monthly_budget_usd
  cloudtrail_log_group_name    = local.create_cloudtrail ? aws_cloudwatch_log_group.cloudtrail[0].name : ""
  create_dashboard             = true
  tags                         = local.tags
  enable_sms                   = var.enable_sms
  sms_monthly_spend_limit_usd  = var.sms_monthly_spend_limit_usd

  alb_arn_suffix              = aws_lb.this.arn_suffix
  alb_target_group_arn_suffix = aws_lb_target_group.app.arn_suffix
  canary_base_url             = var.app_domain != "" ? "https://${var.app_domain}" : "https://${aws_lb.this.dns_name}"

}

# =============================================================================
# ALB CLOUDWATCH ALARMS
# =============================================================================

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${local.name_prefix}-alb-elb-5xx"
  alarm_description   = "ALB 5XX errors — potential app crash or Openn webhook drops"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_ELB_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  statistic           = "Sum"
  threshold           = 10
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.this.arn_suffix
  }

  alarm_actions = [module.observability.operational_alerts_topic_arn]
  ok_actions    = [module.observability.operational_alerts_topic_arn]

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "alb_unhealthy_hosts" {
  alarm_name          = "${local.name_prefix}-alb-unhealthy-hosts"
  alarm_description   = "ALB has unhealthy targets"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.this.arn_suffix
    TargetGroup  = aws_lb_target_group.app.arn_suffix
  }

  alarm_actions = [module.observability.operational_alerts_topic_arn]
  ok_actions    = [module.observability.operational_alerts_topic_arn]

  tags = local.tags
}

# Zero running tasks = the ALB has nothing to route to and every request is a
# 503. This is deliberately separate from alb-unhealthy-hosts: when the service
# drops to zero tasks there are no targets registered at all, so UnHealthyHost
# Count is 0 (not >0) and that alarm stays green through a total outage — which
# is exactly what happened on 2026-07-31, when qa was down 26 times in a week
# and nobody noticed until a developer reported it.
#
# Requires Container Insights, which module.ecs enables.
resource "aws_cloudwatch_metric_alarm" "ecs_no_running_tasks" {
  alarm_name          = "${local.name_prefix}-ecs-no-running-tasks"
  alarm_description   = "ECS service has zero running tasks — the ALB has no targets and is serving 503s"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "RunningTaskCount"
  namespace           = "ECS/ContainerInsights"
  period              = 60
  statistic           = "Maximum"
  threshold           = 1

  # breaching, NOT notBreaching: when the last task dies, Container Insights
  # stops publishing the metric entirely rather than reporting 0. Treating
  # missing data as OK would silence this alarm in precisely the outage it
  # exists to catch.
  treat_missing_data = "breaching"

  dimensions = {
    ClusterName = module.ecs.cluster_name
    ServiceName = aws_ecs_service.app.name
  }

  alarm_actions = [module.observability.operational_alerts_topic_arn]
  ok_actions    = [module.observability.operational_alerts_topic_arn]

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "alb_target_latency" {
  alarm_name          = "${local.name_prefix}-alb-target-latency"
  alarm_description   = "ALB target response time exceeds 3s (p95)"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  extended_statistic  = "p95"
  threshold           = 3
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.this.arn_suffix
    TargetGroup  = aws_lb_target_group.app.arn_suffix
  }

  alarm_actions = [module.observability.operational_alerts_topic_arn]
  ok_actions    = [module.observability.operational_alerts_topic_arn]

  tags = local.tags
}

# =============================================================================
# AI-SPEND BUDGET ALARM (AWS Budgets)
# =============================================================================
# Tracks monthly spend on Bedrock/external AI APIs via AWS Budgets.
# Note: This tracks overall AWS account spend against the budget threshold.
# For per-service AI API tracking (Anthropic/OpenAI), the app should emit
# custom CloudWatch metrics from its token-counting middleware.
# =============================================================================

resource "aws_budgets_budget" "monthly" {
  count = var.monthly_budget_usd > 0 ? 1 : 0

  name         = "${local.name_prefix}-monthly-budget"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # AWS requires every notification to have >=1 subscriber, so emit the
  # notification blocks only when alarm_email_endpoints is non-empty. The
  # budget itself still exists (visible in Cost Explorer) without them.
  dynamic "notification" {
    for_each = length(var.alarm_email_endpoints) > 0 ? [80, 100] : []
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = var.alarm_email_endpoints
    }
  }

  dynamic "notification" {
    for_each = length(var.alarm_email_endpoints) > 0 ? [80] : []
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "FORECASTED"
      subscriber_email_addresses = var.alarm_email_endpoints
    }
  }
}

# =============================================================================
# EVENTBRIDGE SCHEDULER — Cron Jobs
# =============================================================================
# Hits the app's /api/cron/* endpoints on a schedule via API Destination.
# Uses Bearer CRON_SECRET for authentication.
# =============================================================================

locals {
  cron_base_url = var.app_domain != "" ? "https://${var.app_domain}" : "https://${aws_lb.this.dns_name}"

  cron_schedules = {
    reminders   = { path = "/api/cron/proposal-reminders", schedule = "rate(5 minutes)" }
    audit-prune = { path = "/api/cron/audit-prune", schedule = "rate(1 hour)" }
    pdf-health  = { path = "/api/cron/pdf-health", schedule = "rate(15 minutes)" }
  }
}

resource "aws_iam_role" "rds_rotation_redeploy" {
  name = "${local.name_prefix}-rds-rotation-redeploy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "rds_rotation_redeploy" {
  name = "${local.name_prefix}-rds-rotation-redeploy"
  role = aws_iam_role.rds_rotation_redeploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecs:UpdateService"]
        Resource = aws_ecs_service.app.id
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.rds_rotation_redeploy.arn}:*"
      }
    ]
  })
}
resource "aws_cloudwatch_log_group" "rds_rotation_redeploy" {
  name              = "/aws/lambda/${local.name_prefix}-rds-rotation-redeploy"
  retention_in_days = 30

  tags = local.tags
}

data "archive_file" "rds_rotation_redeploy" {
  type        = "zip"
  source_file = "${path.module}/lambda/rds_rotation_redeploy.py"
  output_path = "${path.module}/.terraform/rds_rotation_redeploy.zip"
}

resource "aws_lambda_function" "rds_rotation_redeploy" {
  function_name = "${local.name_prefix}-rds-rotation-redeploy"

  filename         = data.archive_file.rds_rotation_redeploy.output_path
  source_code_hash = data.archive_file.rds_rotation_redeploy.output_base64sha256

  role    = aws_iam_role.rds_rotation_redeploy.arn
  handler = "rds_rotation_redeploy.lambda_handler"
  runtime = "python3.12"

  environment {
    variables = {
      ECS_CLUSTER = module.ecs.cluster_id
      ECS_SERVICE = aws_ecs_service.app.name
    }
  }
}

resource "aws_cloudwatch_event_rule" "rds_rotation_redeploy" {
  name        = "${local.name_prefix}-rds-rotation-redeploy"
  description = "Redeploy ECS service after RDS managed secret rotation succeeds"

  event_pattern = jsonencode({
    source      = ["aws.secretsmanager"]
    detail-type = ["AWS Service Event via CloudTrail"]
    detail = {
      eventSource = ["secretsmanager.amazonaws.com"]
      eventName   = ["RotationSucceeded"]
      additionalEventData = {
        SecretId = [module.rds.master_user_secret_arn]
      }
    }
  })

  tags = local.tags
}

resource "aws_cloudwatch_event_target" "rds_rotation_redeploy" {
  rule = aws_cloudwatch_event_rule.rds_rotation_redeploy.name
  arn  = aws_lambda_function.rds_rotation_redeploy.arn
}

resource "aws_lambda_permission" "rds_rotation_redeploy" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rds_rotation_redeploy.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.rds_rotation_redeploy.arn
}

resource "aws_cloudwatch_metric_alarm" "rds_rotation_redeploy_lambda_errors" {
  alarm_name          = "${local.name_prefix}-rds-rotation-redeploy-lambda-errors"
  alarm_description   = "RDS rotation redeploy Lambda failed. ECS may not have been redeployed after a successful RDS password rotation."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.rds_rotation_redeploy.function_name
  }

  alarm_actions = [module.observability.operational_alerts_topic_arn]
  ok_actions    = [module.observability.operational_alerts_topic_arn]

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "rds_rotation_redeploy_eventbridge_failures" {
  alarm_name          = "${local.name_prefix}-rds-rotation-redeploy-eventbridge-failures"
  alarm_description   = "EventBridge failed to invoke the RDS rotation redeploy Lambda. ECS may not have been redeployed after a successful RDS password rotation."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "FailedInvocations"
  namespace           = "AWS/Events"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    RuleName = aws_cloudwatch_event_rule.rds_rotation_redeploy.name
  }

  alarm_actions = [module.observability.operational_alerts_topic_arn]
  ok_actions    = [module.observability.operational_alerts_topic_arn]

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "ses_bounce_rate" {
  count               = var.environment == "prod" ? 1 : 0
  alarm_name          = "${local.name_prefix}-ses-bounce-rate"
  alarm_description   = "Account-wide (QA + prod) SES bounce rate reached or exceeded 2%. Investigate email sending and recipient quality."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "Reputation.BounceRate"
  namespace           = "AWS/SES"
  period              = 300
  statistic           = "Average"
  threshold           = 0.02
  treat_missing_data  = "ignore"

  alarm_actions = [module.observability.operational_alerts_topic_arn]
  ok_actions    = [module.observability.operational_alerts_topic_arn]

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "ses_complaint_rate" {
  count               = var.environment == "prod" ? 1 : 0
  alarm_name          = "${local.name_prefix}-ses-complaint-rate"
  alarm_description   = "Account-wide (QA + prod) SES complaint rate reached or exceeded 0.05%. Investigate email sending and recipient quality."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "Reputation.ComplaintRate"
  namespace           = "AWS/SES"
  period              = 300
  statistic           = "Average"
  threshold           = 0.0005
  treat_missing_data  = "ignore"

  alarm_actions = [module.observability.operational_alerts_topic_arn]
  ok_actions    = [module.observability.operational_alerts_topic_arn]

  tags = local.tags
}

resource "aws_iam_role" "scheduler" {
  name = "${local.name_prefix}-scheduler-role"

  # events.amazonaws.com: cron fires via EventBridge RULES, not EventBridge
  # Scheduler — Scheduler's CreateSchedule rejects api-destination target ARNs
  # outright (verified empirically against the raw API in ap-southeast-2, both
  # with and without the /uuid suffix). Rules invoke API destinations natively.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "events.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_sqs_queue" "scheduler_dlq" {
  name                      = "${local.name_prefix}-scheduler-dlq"
  message_retention_seconds = 1209600 # 14 days
  tags                      = local.tags
}

resource "aws_iam_role_policy" "scheduler_invoke" {
  name = "${local.name_prefix}-scheduler-invoke"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["events:InvokeApiDestination"]
        Resource = [for k, v in aws_cloudwatch_event_api_destination.cron : v.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = [aws_sqs_queue.scheduler_dlq.arn]
      }
    ]
  })
}

data "aws_secretsmanager_secret_version" "cron_secret" {
  secret_id = module.secrets.secret_arns["cron-secret"]

  depends_on = [module.secrets]
}

resource "aws_cloudwatch_event_connection" "cron" {
  name        = "${local.name_prefix}-cron-connection"
  description = "Connection for Pitch cron endpoints using CRON_SECRET"

  authorization_type = "API_KEY"

  auth_parameters {
    api_key {
      key   = "Authorization"
      value = "Bearer ${data.aws_secretsmanager_secret_version.cron_secret.secret_string}"
    }
  }
}

resource "aws_cloudwatch_event_api_destination" "cron" {
  for_each = local.cron_schedules

  name                             = "${local.name_prefix}-cron-${each.key}"
  description                      = "API destination for Pitch cron: ${each.key}"
  invocation_endpoint              = "${local.cron_base_url}${each.value.path}"
  http_method                      = "GET" # the app's /api/cron/* routes are GET-only
  invocation_rate_limit_per_second = 5
  connection_arn                   = aws_cloudwatch_event_connection.cron.arn
}

# EventBridge RULES (not Scheduler): Scheduler cannot target API destinations
# (CreateSchedule rejects the ARN — verified against the raw API). Rules invoke
# them natively. All schedules are rate() expressions, so no timezone is lost.
resource "aws_cloudwatch_event_rule" "cron" {
  for_each = local.cron_schedules

  name                = "${local.name_prefix}-cron-${each.key}"
  description         = "Pitch cron: POST ${each.value.path}"
  schedule_expression = each.value.schedule
  state               = "ENABLED"
  tags                = local.tags
}

resource "aws_cloudwatch_event_target" "cron" {
  for_each = local.cron_schedules

  rule     = aws_cloudwatch_event_rule.cron[each.key].name
  arn      = aws_cloudwatch_event_api_destination.cron[each.key].arn
  role_arn = aws_iam_role.scheduler.arn

  retry_policy {
    maximum_event_age_in_seconds = 300
    maximum_retry_attempts       = 2
  }

  dead_letter_config {
    arn = aws_sqs_queue.scheduler_dlq.arn
  }
}

# Rule-target DLQ delivery is performed by EventBridge itself, so the QUEUE
# policy must allow events.amazonaws.com (the target role's sqs:SendMessage
# only covers Scheduler-style delivery).
resource "aws_sqs_queue_policy" "scheduler_dlq" {
  queue_url = aws_sqs_queue.scheduler_dlq.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowEventBridgeDLQ"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.scheduler_dlq.arn
      Condition = {
        ArnEquals = { "aws:SourceArn" = [for k, v in aws_cloudwatch_event_rule.cron : v.arn] }
      }
    }]
  })
}

output "cron_schedule_arns" {
  description = "ARNs of the cron EventBridge rules"
  value       = { for k, v in aws_cloudwatch_event_rule.cron : k => v.arn }
}

# =============================================================================
# SES DOMAIN IDENTITY (email sending)
# =============================================================================

resource "aws_ses_domain_identity" "this" {
  count  = var.app_domain != "" ? 1 : 0
  domain = var.app_domain
}

resource "aws_ses_domain_dkim" "this" {
  count  = var.app_domain != "" ? 1 : 0
  domain = aws_ses_domain_identity.this[0].domain
}

resource "aws_ses_domain_identity_verification" "this" {
  count  = var.app_domain != "" && local.create_dns ? 1 : 0
  domain = aws_ses_domain_identity.this[0].id

  depends_on = [aws_route53_record.ses_verification]
}

resource "aws_ses_domain_mail_from" "this" {
  count            = var.app_domain != "" ? 1 : 0
  domain           = aws_ses_domain_identity.this[0].domain
  mail_from_domain = "mail.${var.app_domain}"
}

resource "aws_route53_record" "ses_verification" {
  count   = var.app_domain != "" && local.create_dns ? 1 : 0
  zone_id = local.zone_id
  name    = "_amazonses.${var.app_domain}"
  type    = "TXT"
  ttl     = 600
  records = [aws_ses_domain_identity.this[0].verification_token]
}

resource "aws_route53_record" "ses_dkim" {
  count   = var.app_domain != "" && local.create_dns ? 3 : 0
  zone_id = local.zone_id
  name    = "${aws_ses_domain_dkim.this[0].dkim_tokens[count.index]}._domainkey.${var.app_domain}"
  type    = "CNAME"
  ttl     = 600
  records = ["${aws_ses_domain_dkim.this[0].dkim_tokens[count.index]}.dkim.amazonses.com"]
}

resource "aws_route53_record" "ses_mail_from_mx" {
  count   = var.app_domain != "" && local.create_dns ? 1 : 0
  zone_id = local.zone_id
  name    = "mail.${var.app_domain}"
  type    = "MX"
  ttl     = 600
  records = ["10 feedback-smtp.${var.region}.amazonses.com"]
}

resource "aws_route53_record" "ses_mail_from_spf" {
  count   = var.app_domain != "" && local.create_dns ? 1 : 0
  zone_id = local.zone_id
  name    = "mail.${var.app_domain}"
  type    = "TXT"
  ttl     = 600
  records = ["v=spf1 include:amazonses.com -all"]
}

# =============================================================================
# SES CONFIGURATION SET (per-environment sending controls)
# =============================================================================
#
# WHY THIS EXISTS
#
# SES's most important controls — sandbox vs production access, the 24h sending
# quota, and account sender reputation — are scoped to an AWS ACCOUNT + REGION,
# not to a resource. With qa/staging/prod sharing one account, a test run that
# bounces enough mail can trip the account-wide reputation guard and pause
# sending for EVERY environment.
#
# A per-env configuration set is the only primitive that claws segregation back:
#   * reputation metrics are tracked per configuration set, so a bad env is
#     attributable instead of anonymous inside one account-wide number
#   * sending_enabled is a per-env kill switch — pause qa without touching prod
#   * the suppression list is per-env, so a bounce in qa does not suppress that
#     recipient for prod
#
# APPLICATION CHANGE REQUIRED
#
# The app must name this configuration set on send. Its SendEmailCommand
# (src/lib/integrations/ses.ts) does not set ConfigurationSetName today, so
# until it does, this set exists but nothing routes through it.
#
# Making it the identity's DEFAULT set instead (so no app change is needed) is
# possible only by managing the identity with aws_sesv2_email_identity — the
# provider has no standalone attachment resource. That would mean re-importing
# qa.pitch.openn.com, which is already verified with DKIM and a custom MAIL
# FROM, so it is deliberately NOT done here. Revisit if we ever migrate the
# SES resources from the v1 to the v2 provider resources wholesale.

resource "aws_sesv2_configuration_set" "this" {
  count                  = var.app_domain != "" ? 1 : 0
  configuration_set_name = local.name_prefix

  delivery_options {
    tls_policy = "REQUIRE"
  }

  reputation_options {
    reputation_metrics_enabled = true
  }

  sending_options {
    sending_enabled = true
  }

  # Inherit the account-level suppression list. Suppressed recipients are
  # skipped rather than hard-bounced again, which protects the bounce rate.
  suppression_options {
    suppressed_reasons = ["BOUNCE", "COMPLAINT"]
  }

  tags = local.tags
}

# Publish send/bounce/complaint/delivery events as CloudWatch metrics dimensioned
# by configuration set, so each environment's deliverability is separable on a
# dashboard. CloudWatch (not SNS/Firehose) keeps this dependency-free — nothing
# to subscribe to and no extra spend.
resource "aws_sesv2_configuration_set_event_destination" "cloudwatch" {
  count                  = var.app_domain != "" ? 1 : 0
  configuration_set_name = aws_sesv2_configuration_set.this[0].configuration_set_name
  event_destination_name = "cloudwatch"

  event_destination {
    enabled = true
    matching_event_types = [
      "SEND",
      "DELIVERY",
      "BOUNCE",
      "COMPLAINT",
      "REJECT",
      "RENDERING_FAILURE",
      "DELIVERY_DELAY",
    ]

    cloud_watch_destination {
      dimension_configuration {
        dimension_name          = "ses:configuration-set"
        dimension_value_source  = "MESSAGE_TAG"
        default_dimension_value = local.name_prefix
      }
    }
  }
}

# =============================================================================
# CLOUDTRAIL (security audit trail — prod-only singleton, account-wide)
# =============================================================================

locals {
  create_cloudtrail    = var.environment == "prod"
  cloudtrail_trail_arn = "arn:aws:cloudtrail:${var.region}:${data.aws_caller_identity.current.account_id}:trail/pitchai-cloudtrail"
}

resource "aws_cloudwatch_log_group" "cloudtrail" {
  count             = local.create_cloudtrail ? 1 : 0
  name              = "/aws/cloudtrail/pitchai"
  retention_in_days = 365
  tags              = local.tags
}

resource "aws_iam_role" "cloudtrail" {
  count = local.create_cloudtrail ? 1 : 0
  name  = "pitchai-cloudtrail"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudtrail.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceArn" = local.cloudtrail_trail_arn
        }
      }
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "cloudtrail_logs" {
  count = local.create_cloudtrail ? 1 : 0
  name  = "cloudtrail-to-cloudwatch"
  role  = aws_iam_role.cloudtrail[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.cloudtrail[0].arn}:*"
    }]
  })
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "cloudtrail" {
  count         = local.create_cloudtrail ? 1 : 0
  bucket        = "pitchai-cloudtrail"
  force_destroy = false
  tags          = local.tags
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  count  = local.create_cloudtrail ? 1 : 0
  bucket = aws_s3_bucket.cloudtrail[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  count                   = local.create_cloudtrail ? 1 : 0
  bucket                  = aws_s3_bucket.cloudtrail[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail" {
  count  = local.create_cloudtrail ? 1 : 0
  bucket = aws_s3_bucket.cloudtrail[0].id

  rule {
    id     = "expire-trail-objects"
    status = "Enabled"

    # empty filter => rule applies to all objects (required in AWS provider v5;
    # omitting both filter and prefix is deprecated and will error in future).
    filter {}

    expiration {
      days = 400
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  count  = local.create_cloudtrail ? 1 : 0
  bucket = aws_s3_bucket.cloudtrail[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = ["${aws_s3_bucket.cloudtrail[0].arn}", "${aws_s3_bucket.cloudtrail[0].arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "CloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.cloudtrail[0].arn
        Condition = { StringEquals = { "aws:SourceArn" = local.cloudtrail_trail_arn } }
      },
      {
        Sid       = "CloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.cloudtrail[0].arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"  = "bucket-owner-full-control"
            "aws:SourceArn" = local.cloudtrail_trail_arn
          }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.cloudtrail]
}

resource "aws_cloudtrail" "this" {
  count                         = local.create_cloudtrail ? 1 : 0
  name                          = "pitchai-cloudtrail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail[0].id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true

  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.cloudtrail[0].arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.cloudtrail[0].arn

  event_selector {
    read_write_type           = "All"
    include_management_events = true
  }

  depends_on = [aws_s3_bucket_policy.cloudtrail]

  tags = local.tags
}

# =============================================================================
# GITHUB OIDC + CI/CD ROLE
# =============================================================================

module "github_oidc" {
  source = "./modules/aws/github-oidc"

  role_name            = "${local.name_prefix}-github-actions"
  github_repositories  = var.github_repositories
  oidc_subject_claims  = var.environment == "prod" ? flatten([for repo in var.github_repositories : ["repo:${repo}:ref:refs/heads/main", "repo:${repo}:environment:production"]]) : []
  create_oidc_provider = var.create_github_oidc_provider

  attach_terraform_policy = true
  attach_deploy_policy    = true
  terraform_state_bucket  = var.terraform_state_bucket

  ecr_repository_arns = [module.ecr.repository_arn]
  ecs_cluster_arns    = [module.ecs.cluster_arn]
  ecs_task_role_arns = [
    module.ecs.task_execution_role_arn,
    module.ecs.task_role_arn,
  ]
  log_group_arns = [module.ecs.log_group_arn]

  tags = local.tags
}
