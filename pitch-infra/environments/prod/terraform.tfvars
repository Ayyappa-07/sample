environment = "prod"
region      = "ap-southeast-2"

# Networking — 3 AZs for prod HA
vpc_cidr = "10.50.32.0/20"
public_subnets = {
  az1 = { cidr = "10.50.32.0/24", availability_zone = "ap-southeast-2a" }
  az2 = { cidr = "10.50.33.0/24", availability_zone = "ap-southeast-2b" }
  az3 = { cidr = "10.50.34.0/24", availability_zone = "ap-southeast-2c" }
}
private_subnets = {
  az1 = { cidr = "10.50.36.0/24", availability_zone = "ap-southeast-2a" }
  az2 = { cidr = "10.50.37.0/24", availability_zone = "ap-southeast-2b" }
  az3 = { cidr = "10.50.38.0/24", availability_zone = "ap-southeast-2c" }
}

# App
# app_image is set by CI after first ECR push; omit to use default "initial" for bootstrap
task_cpu      = 1024
task_memory   = 2048
desired_count = 3
max_capacity  = 10
pg_pool_max   = 30

# RDS — Graviton production grade
rds_instance_class        = "db.r7g.large"
rds_allocated_storage     = 50
rds_max_allocated_storage = 500

# Redis — Graviton with replica
redis_node_type = "cache.r7g.large"

# DNS / TLS
app_domain      = "pitch.openn.com"
route53_zone_id = "Z09326591LYPYKFNFVVIG"

enable_sms                    = true
sms_origination_identity_arn  = "arn:aws:sms-voice:ap-southeast-2:523706030753:sender-id/OPENN/AU"
ses_allowed_recipient_domains = []
# When enabling SES production access, also set
# ses_allow_unrestricted_recipients = true
ses_production_access = false

# Security
enable_waf             = true
enable_geo_restriction = true
geo_rule_action        = "COUNT"

enable_vpc_endpoints = true
enable_cloudfront    = true

alarm_email_endpoints = ["rishabh@openn.com", "ayyappa@skybytech.com"]
monthly_budget_usd    = 1500

# CI/CD
github_repositories    = ["OpennRE/pitch-infra", "OpennRE/Pitch"]
terraform_state_bucket = "pitchai-terraform-state"

tags = {
  Team = "platform"
}
