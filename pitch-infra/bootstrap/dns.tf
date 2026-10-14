# =============================================================================
# SHARED DNS ZONE — pitch.openn.com
# =============================================================================
# One hosted zone in the Pitch account holds ALL env records:
#   qa.pitch.openn.com / staging.pitch.openn.com / pitch.openn.com (prod apex).
# openn.com (prod, legacy account) delegates this subtree ONCE via a single NS
# record — no further openn.com changes for any env. Created during the qa
# bootstrap (the first env, same as the shared state bucket); staging/prod
# bootstrap runs never recreate it.
# =============================================================================

resource "aws_route53_zone" "shared" {
  count = var.environment == "qa" ? 1 : 0

  name    = "pitch.openn.com"
  comment = "Shared Pitch DNS — qa/staging/prod records; delegated from openn.com"

  tags = {
    Project   = "pitchai"
    ManagedBy = "terraform-bootstrap"
  }
}

output "shared_dns_zone_id" {
  description = "Route53 zone id for pitch.openn.com — set as route53_zone_id in every env's tfvars."
  value       = try(aws_route53_zone.shared[0].zone_id, null)
}

output "shared_dns_name_servers" {
  description = "NS records to delegate pitch.openn.com from the openn.com zone (one-time, in the legacy account)."
  value       = try(aws_route53_zone.shared[0].name_servers, null)
}
