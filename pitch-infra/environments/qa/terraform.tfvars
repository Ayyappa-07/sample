environment = "qa"
region      = "ap-southeast-2"

# Networking — /20 CIDR, 3 AZs
vpc_cidr = "10.50.0.0/20"
# az3 added 2026-08-03. ap-southeast-2 has three AZs but the VPC only covered
# two, so ECS could ask for Fargate Spot capacity in 2a and 2b and nowhere else
# — a third of the region was unreachable. Both SpotInterruptions we traced on
# 2026-07-31 were in 2b, and the "Capacity is unavailable" errors had only one
# other zone to fall back to.
#
# Additive and safe: the networking module keys subnets with for_each over this
# map, so az1/az2 are untouched (no renumbering, no recreation). CIDRs are the
# next free /24s inside the 10.50.0.0/20 VPC. Private subnets share the single
# NAT gateway route table in non-prod, and the ALB gains a third AZ in place.
public_subnets = {
  az1 = { cidr = "10.50.0.0/24", availability_zone = "ap-southeast-2a" }
  az2 = { cidr = "10.50.1.0/24", availability_zone = "ap-southeast-2b" }
  az3 = { cidr = "10.50.2.0/24", availability_zone = "ap-southeast-2c" }
}
private_subnets = {
  az1 = { cidr = "10.50.4.0/24", availability_zone = "ap-southeast-2a" }
  az2 = { cidr = "10.50.5.0/24", availability_zone = "ap-southeast-2b" }
  az3 = { cidr = "10.50.6.0/24", availability_zone = "ap-southeast-2c" }
}

# App — cost-optimised for QA
# app_image is set by CI after first ECR push; omit to use default "initial" for bootstrap
task_cpu    = 512 # non-standalone `next start` + tsx seed; 256/512 was OOM-prone
task_memory = 1024
# desired_count 2, not 1. With a single task, one Fargate SpotInterruption takes
# the service to zero and the ALB serves 503 until Spot capacity returns. Two
# tasks means an interruption leaves a healthy target and users see nothing —
# demonstrated live on 2026-07-31, where the same interruption that had caused a
# 30-minute outage became a non-event once a second task was running.
#
# Two Spot tasks (~$13/mo) are also CHEAPER than one on-demand task (~$21/mo),
# so this buys resilience and saves money versus moving off Spot.
#
# This value is load-bearing beyond the service: aws_appautoscaling_target sets
# min_capacity = var.desired_count. That is why bumping the service to 2 with
# the AWS CLI did not stick on 2026-07-31 — Terraform ignores desired_count
# changes, but autoscaling scaled straight back in to min_capacity = 1 on an
# idle QA environment. Changing it here is the only durable fix.
desired_count = 2

# Raised 2 -> 4 so scaling out is still possible. With min_capacity now 2, a
# max of 2 would leave the target-tracking policies with nowhere to go.
max_capacity = 4

# RDS — Graviton minimal
rds_instance_class        = "db.t4g.small"
rds_allocated_storage     = 20
rds_max_allocated_storage = 50

# Redis — Graviton single node, no replication
redis_node_type = "cache.t4g.micro"

# DNS / TLS — nested under the shared pitch.openn.com zone (bootstrap-owned).
# route53_zone_id set => module uses the existing shared zone (creates qa's
# record + cert IN it), never a per-env zone. staging/prod use the same zone id.
app_domain      = "qa.pitch.openn.com"
route53_zone_id = "Z09326591LYPYKFNFVVIG"

# Openn SSO config (OPENN_SSO_* / OPENN_API_BASE_URL / OPENN_GLOBAL_LOGOUT_URL /
# OPENN_SSO_SESSION_*) is NOT set here — it's owned by the Pitch deploy workflow
# via GitHub Actions variables (repo OpennRE/Pitch). OPENN_PITCH_SYNC_API_KEY is
# a secret in Secrets Manager (pitchai-qa/openn-pitch-sync-api-key).
# NEXT_PUBLIC_APP_URL is derived from app_public_url below (https://test.pitch.openn.com).

# Messaging — SES email + SNS SMS for the app (PA-111).
# The SES identity qa.pitch.openn.com is already verified (DKIM SUCCESS, custom
# MAIL FROM mail.qa.pitch.openn.com SUCCESS). enable_sms grants the Resource "*"
# SNS Publish that SMS-to-a-phone-number requires; topic-scoped Publish does not
# cover it, which is why sendSms() would 403 today.
#
# ses_allowed_recipient_domains is deliberately EMPTY for now: the account is
# still in the SES sandbox, which already restricts sends to verified addresses,
# so a domain allowlist would only get in devs' way. Populate it (e.g.
# ["openn.com", "acubetechnologies.in"]) BEFORE SES production access is granted
# on this account — otherwise a qa test run can email real people, and the
# resulting bounces count against the account-wide reputation shared with prod.
enable_sms = true

# Openn's AU-registered sender ID, owned by account 523706030753 and shared to
# this account via AWS RAM (share "openn-sms-sender-id-share"). Using it rather
# than registering a second sender ID avoids ~2-3 weeks of carrier approval and
# keeps ONE opt-out list across Openn and Pitch — a split suppression list is a
# compliance problem, not just an inconvenience.
#
# The AU registration means this identity can ONLY originate to AU destinations;
# AWS rejects it outright for other countries. Test with +614... numbers.
sms_origination_identity_arn  = "arn:aws:sms-voice:ap-southeast-2:523706030753:sender-id/OPENN/AU"
ses_allowed_recipient_domains = []

# Declares that this account is still in the SES sandbox in ap-southeast-2
# (verified: ProductionAccessEnabled = false). AWS exposes no data source for
# this, so it is a declaration — but it is enforced: flipping it to true while
# ses_allowed_recipient_domains is empty fails the plan, so the allowlist
# cannot be silently forgotten at the exact moment it starts to matter.
ses_production_access = false

# WAF off for QA
enable_waf = true

# Enable WAF geo restriction in COUNT mode for observation
enable_geo_restriction = true
geo_rule_action        = "COUNT"

# CloudFront on for QA (PA-84). Fronts the whole qa.pitch.openn.com domain:
# the default behavior passes dynamic/auth traffic straight through to the ALB
# (all cookies + Host/Authorization forwarded, TTL 0), so sessions and the API
# are unaffected. The point of enabling it is the /api/public/media/* behavior
# below, which edge-caches uploaded media that the app serves from the private
# S3 bucket via its own credentials — the bucket stays fully private (all four
# public-access blocks and SSE-KMS unchanged), and direct S3 URLs still 403.
#
# Enabling this provisions a new CloudFront distribution and a us-east-1 ACM
# cert (auto-validated via the shared Route53 zone), then cuts the qa A record
# from the ALB alias to the CloudFront alias in the same apply. Allow ~15 min
# for the distribution to deploy and the cert to validate.
enable_cloudfront = true

# VPC endpoints off to save cost in QA
enable_vpc_endpoints = false

alarm_email_endpoints = ["rishabh@openn.com", "ayyappa@skybytech.com"]

# CI/CD
github_repositories    = ["OpennRE/pitch-infra", "OpennRE/Pitch"]
terraform_state_bucket = "pitchai-terraform-state"

tags = {
  Team = "platform"
}

extra_domain_aliases = ["test.pitch.openn.com"]

# Devs use test.; app_domain stays qa. because it is pinned to the ACM certs and
# the SES identity named in the open production-access request. Without this the
# app redirects test. visitors to qa. after SSO and the host-only session cookie
# is lost, producing an infinite login loop.
app_public_url = "https://test.pitch.openn.com"
