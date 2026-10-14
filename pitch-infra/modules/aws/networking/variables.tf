# =============================================================================
# AWS NETWORKING MODULE - VARIABLES
# =============================================================================

variable "vpc_name" {
  description = "Name of the VPC"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "public_subnets" {
  description = "Map of public subnet configurations"
  type = map(object({
    cidr              = string
    availability_zone = string
  }))
  default = {}
}

variable "private_subnets" {
  description = "Map of private subnet configurations"
  type = map(object({
    cidr              = string
    availability_zone = string
  }))
  default = {}
}

variable "enable_nat_gateway" {
  description = "Enable NAT Gateway for private subnets"
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "Use a single NAT Gateway instead of one per AZ"
  type        = bool
  default     = false
}

variable "enable_flow_logs" {
  description = "Enable VPC Flow Logs for SOC 2 compliance"
  type        = bool
  default     = true
}

variable "flow_logs_retention_days" {
  description = "CloudWatch log group retention for VPC flow logs"
  type        = number
  default     = 365
}

variable "enable_vpc_endpoints" {
  description = "Enable the essential VPC endpoints used on every task start (S3 gateway + ECR api/dkr, CloudWatch Logs, Secrets Manager interface) — these keep high-frequency AWS traffic off NAT."
  type        = bool
  default     = true
}

variable "enable_optional_vpc_endpoints" {
  description = "Also create the rarely-needed interface endpoints (SSM/SSMMessages/EC2Messages for ECS Exec, SES/SNS/STS). Off by default — each is ~$7/mo/AZ and this traffic is low-volume (or unused), so NAT is cheaper. Turn on only for ECS Exec or high email/SMS volume."
  type        = bool
  default     = false
}

variable "kms_key_arn" {
  description = "KMS key ARN for encrypting CloudWatch log groups. If null, uses default encryption."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
