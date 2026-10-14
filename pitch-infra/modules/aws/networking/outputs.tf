# =============================================================================
# AWS NETWORKING MODULE - OUTPUTS
# =============================================================================

output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC"
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "IDs of public subnets"
  value       = [for s in aws_subnet.public : s.id]
}

output "private_subnet_ids" {
  description = "IDs of private subnets"
  value       = [for s in aws_subnet.private : s.id]
}

output "public_subnet_cidrs" {
  description = "CIDR blocks of public subnets"
  value       = [for s in aws_subnet.public : s.cidr_block]
}

output "private_subnet_cidrs" {
  description = "CIDR blocks of private subnets"
  value       = [for s in aws_subnet.private : s.cidr_block]
}

output "nat_gateway_ids" {
  description = "IDs of NAT Gateways"
  value       = [for nat in aws_nat_gateway.this : nat.id]
}

output "nat_gateway_public_ips" {
  description = "Public IPs of NAT Gateways"
  value       = [for eip in aws_eip.nat : eip.public_ip]
}

output "internet_gateway_id" {
  description = "ID of the Internet Gateway"
  value       = length(aws_internet_gateway.this) > 0 ? aws_internet_gateway.this[0].id : null
}

output "flow_log_group_name" {
  description = "CloudWatch log group name for VPC flow logs"
  value       = var.enable_flow_logs ? aws_cloudwatch_log_group.flow_logs[0].name : null
}

output "private_route_table_ids" {
  description = "IDs of private route tables"
  value       = [for rt in aws_route_table.private : rt.id]
}

output "vpc_endpoints_security_group_id" {
  description = "Security group ID for VPC endpoints"
  value       = var.enable_vpc_endpoints ? aws_security_group.vpc_endpoints[0].id : null
}
