# =============================================================================
# PITCH INFRASTRUCTURE - VARIABLES
# =============================================================================

# -----------------------------------------------------------------------------
# CORE
# -----------------------------------------------------------------------------

variable "environment" {
  description = "Environment name (qa, staging, prod)"
  type        = string

  validation {
    condition     = contains(["qa", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: qa, staging, prod."
  }
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-2"
}

variable "assume_role_arn" {
  description = "IAM role ARN to assume for this environment's AWS account. Leave empty when running with direct credentials (e.g. GitHub OIDC already assumes into the correct account)."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}

# -----------------------------------------------------------------------------
# NETWORKING
# -----------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.50.0.0/16"
}

variable "public_subnets" {
  description = "Map of public subnets"
  type = map(object({
    cidr              = string
    availability_zone = string
  }))
  default = {
    az1 = {
      cidr              = "10.50.1.0/24"
      availability_zone = "ap-southeast-2a"
    }
    az2 = {
      cidr              = "10.50.2.0/24"
      availability_zone = "ap-southeast-2b"
    }
    az3 = {
      cidr              = "10.50.3.0/24"
      availability_zone = "ap-southeast-2c"
    }
  }
}

variable "private_subnets" {
  description = "Map of private subnets"
  type = map(object({
    cidr              = string
    availability_zone = string
  }))
  default = {
    az1 = {
      cidr              = "10.50.11.0/24"
      availability_zone = "ap-southeast-2a"
    }
    az2 = {
      cidr              = "10.50.12.0/24"
      availability_zone = "ap-southeast-2b"
    }
    az3 = {
      cidr              = "10.50.13.0/24"
      availability_zone = "ap-southeast-2c"
    }
  }
}

variable "enable_vpc_endpoints" {
  description = "Enable the essential VPC endpoints (S3 gateway + ECR api/dkr, Logs, Secrets Manager) that keep per-task-start traffic off NAT."
  type        = bool
  default     = true
}

variable "enable_optional_vpc_endpoints" {
  description = "Also create the rarely-needed interface endpoints (SSM×3 for ECS Exec, SES/SNS/STS). Off by default — low-volume/unused traffic, NAT is cheaper. ~$7/mo/AZ each."
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# APPLICATION
# -----------------------------------------------------------------------------

variable "app_image" {
  description = "Container image URI for the Pitch Next.js app. Use 'initial' for first-time bootstrap before ECR exists."
  type        = string
  default     = "initial"
}

variable "app_domain" {
  description = "Application domain name (e.g. app.pitchai.io). Leave empty to use ALB DNS."
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# MESSAGING (SES email / SNS SMS) — see the SES CONFIGURATION SET block in
# main.tf for why per-env segregation is limited in a shared AWS account.
# -----------------------------------------------------------------------------

variable "sms_origination_identity_arn" {
  description = "ARN of the SMS origination identity. Pitch uses Openn's AU-registered OPENN sender ID, shared from account 523706030753 via AWS RAM, so both products share one opt-out list rather than each registering a sender ID (~2-3 weeks) and splitting suppression. Empty disables the SMS IAM grant."
  type        = string
  default     = ""
}

variable "enable_sms" {
  description = "Grant the task role sns:Publish on \"*\" so the app can send SMS to phone numbers. Topic-scoped Publish does NOT cover SMS, so sendSms() 403s without this."
  type        = bool
  default     = false
}

variable "ses_allowed_recipient_domains" {
  description = "Restrict which recipient domains the app may email (e.g. [\"openn.com\"]). Leave empty while the account is in the SES sandbox — sandbox already blocks unverified recipients. Set this for non-prod BEFORE requesting SES production access, so a test run cannot email real customers and damage account-wide sender reputation."
  type        = list(string)
  default     = []
}

variable "ses_allow_unrestricted_recipients" {
  description = "Declare that this environment may email ANY recipient. Only meaningful with ses_production_access = true and an empty ses_allowed_recipient_domains. This is the explicit opt-out from the allowlist guard and is intended for prod, where emailing arbitrary customers is the point — non-prod should set ses_allowed_recipient_domains instead."
  type        = bool
  default     = false
}

variable "ses_production_access" {
  description = "Set true once this AWS account has SES production access (out of the sandbox) in this region. AWS exposes no data source for this, so it is a declaration. Enforced: true with an empty ses_allowed_recipient_domains fails the plan — the sandbox is the only thing making an empty allowlist safe."
  type        = bool
  default     = false
}

variable "domain_api" {
  description = "API domain (e.g. api.pitchai.io). Passed as DOMAIN_API env var."
  type        = string
  default     = ""
}

variable "domain_openn_webhook" {
  description = "Openn webhook callback domain. Passed as DOMAIN_OPENN_WEBHOOK env var."
  type        = string
  default     = ""
}

variable "container_port" {
  description = "Port the Next.js app listens on"
  type        = number
  default     = 5000
}

variable "task_cpu" {
  description = "CPU units for the app task (1 vCPU = 1024)"
  type        = number
  default     = 512
}

variable "task_memory" {
  description = "Memory (MiB) for the app task"
  type        = number
  default     = 1024
}

variable "desired_count" {
  description = "Desired number of app tasks"
  type        = number
  default     = 2
}

variable "max_capacity" {
  description = "Maximum ECS service capacity for autoscaling"
  type        = number
  default     = 6
}

variable "pg_pool_max" {
  description = "Maximum connections in the app's PG pool"
  type        = number
  default     = 20
}

variable "autoscaling_requests_per_target" {
  description = "Target ALB requests per ECS task before scaling out"
  type        = number
  default     = 1000
}

# -----------------------------------------------------------------------------
# OPENN SSO INTEGRATION
# -----------------------------------------------------------------------------
# The Openn SSO config (OPENN_SSO_* / OPENN_API_BASE_URL /
# OPENN_GLOBAL_LOGOUT_URL / OPENN_SSO_SESSION_*) is intentionally NOT modelled
# here. It's owned by the Pitch app's deploy workflow via GitHub Actions
# variables, which injects it into the ECS task-def env at deploy time. The ECS
# service uses ignore_changes=[task_definition] so Terraform never fights it.
# OPENN_PITCH_SYNC_API_KEY stays a Secrets Manager secret (see module.secrets).

# -----------------------------------------------------------------------------
# RDS
# -----------------------------------------------------------------------------

variable "rds_instance_class" {
  description = "RDS instance class (use Graviton: db.t4g.*, db.r7g.*)"
  type        = string
  default     = "db.t4g.medium"
}

variable "rds_allocated_storage" {
  description = "Initial RDS storage in GB"
  type        = number
  default     = 20
}

variable "rds_max_allocated_storage" {
  description = "Maximum RDS storage for autoscaling in GB"
  type        = number
  default     = 100
}

# -----------------------------------------------------------------------------
# REDIS
# -----------------------------------------------------------------------------

variable "redis_node_type" {
  description = "ElastiCache node type (use Graviton: cache.t4g.*, cache.r7g.*)"
  type        = string
  default     = "cache.t4g.medium"
}

# -----------------------------------------------------------------------------
# DNS / TLS
# -----------------------------------------------------------------------------

variable "route53_zone_id" {
  description = "Existing Route53 hosted zone ID. If set, creates DNS records in this zone. If empty and app_domain is set, creates a new hosted zone."
  type        = string
  default     = ""
}

variable "acm_certificate_arn" {
  description = "Pre-existing ACM certificate ARN. If set, skips creating a new cert. Takes priority over auto-created cert."
  type        = string
  default     = ""
}

variable "create_dns_zone" {
  description = "Create a new Route53 hosted zone for app_domain. Only used when route53_zone_id is empty."
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# WAF
# -----------------------------------------------------------------------------

variable "enable_waf" {
  description = "Enable WAF (attached to CloudFront if enabled, otherwise ALB)"
  type        = bool
  default     = false
}

variable "enable_cloudfront" {
  description = "Enable CloudFront distribution in front of ALB for static asset caching"
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# OBSERVABILITY
# -----------------------------------------------------------------------------

variable "alarm_email_endpoints" {
  description = "Email addresses to receive alarm notifications"
  type        = list(string)
  default     = []
}

variable "monthly_budget_usd" {
  description = "Monthly budget in USD for cost alarm"
  type        = number
  default     = 500
}


# -----------------------------------------------------------------------------
# CI/CD (GitHub OIDC)
# -----------------------------------------------------------------------------

variable "github_repositories" {
  description = "GitHub repositories allowed to assume the deploy role (format: org/repo)"
  type        = list(string)
  default     = []
}

variable "create_github_oidc_provider" {
  description = "Create the GitHub OIDC provider (set false if it already exists in this account)"
  type        = bool
  default     = false
}

variable "terraform_state_bucket" {
  description = "S3 bucket name for Terraform state (used in CI/CD role policy)"
  type        = string
  default     = ""
}

# WAF Geo Restriction

variable "enable_geo_restriction" {
  description = "Enable geographic restriction in AWS WAF"
  type        = bool
  default     = false
}

variable "geo_rule_action" {
  description = "Action for the WAF geo restriction rule"
  type        = string
  default     = "BLOCK"

  validation {
    condition     = contains(["BLOCK", "COUNT"], upper(var.geo_rule_action))
    error_message = "geo_rule_action must be BLOCK or COUNT."
  }
}
variable "sms_monthly_spend_limit_usd" {
  type    = number
  default = 350
}

variable "app_public_url" {
  description = <<-EOT
    Public URL the application treats as its own origin — sets NEXT_PUBLIC_APP_URL,
    NEXTAUTH_URL and DOMAIN_APP on the task definition.

    Defaults to "https://" plus app_domain. Set this only when the app is reached on a
    name from extra_domain_aliases rather than on app_domain itself. app_domain
    cannot be reused for that: it is also the ACM certificates' domain_name (both
    are immutable, so changing it forces replacement), the SES from-address and
    domain identity, and the Route53 record name.

    Must be a full origin including scheme and no trailing slash.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.app_public_url == "" || can(regex("^https?://[^/]+$", var.app_public_url))
    error_message = "app_public_url must be a scheme-qualified origin with no path or trailing slash (e.g. https://test.pitch.openn.com)."
  }
}

variable "extra_domain_aliases" {
  description = "Additional domain aliases to add to the CloudFront distribution"
  type        = list(string)
  default     = []
}

variable "allowed_country_codes" {
  description = "Countries allowed by the WAF geo restriction rule"
  type        = list(string)
  default     = ["AU", "NZ"]
}
