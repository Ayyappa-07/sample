# =============================================================================
# AWS NETWORKING MODULE
# =============================================================================
# VPC with public/private subnets, NAT Gateway, VPC Flow Logs, and VPC Endpoints
# SOC 2 Controls: CC6.1 (network segmentation), CC6.6 (private access), CC7.2 (flow logs)
# =============================================================================

data "aws_caller_identity" "current" {}

locals {
  name_prefix = var.vpc_name

  common_tags = merge(var.tags, {
    Module = "aws/networking"
  })

  # Determine NAT Gateway count
  nat_gateway_count = var.enable_nat_gateway ? (var.single_nat_gateway ? 1 : length(var.public_subnets)) : 0

  # Get list of public subnet keys for NAT gateway association
  public_subnet_keys = keys(var.public_subnets)
}

# -----------------------------------------------------------------------------
# VPC
# -----------------------------------------------------------------------------

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, {
    Name = local.name_prefix
  })
}

# -----------------------------------------------------------------------------
# INTERNET GATEWAY
# -----------------------------------------------------------------------------

resource "aws_internet_gateway" "this" {
  count = length(var.public_subnets) > 0 ? 1 : 0

  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-igw"
  })
}

# -----------------------------------------------------------------------------
# PUBLIC SUBNETS
# -----------------------------------------------------------------------------

resource "aws_subnet" "public" {
  for_each = var.public_subnets

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.availability_zone
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name                     = "${local.name_prefix}-public-${each.key}"
    Type                     = "public"
    "kubernetes.io/role/elb" = "1"
  })
}

resource "aws_route_table" "public" {
  count = length(var.public_subnets) > 0 ? 1 : 0

  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-public-rt"
  })
}

resource "aws_route" "public_internet" {
  count = length(var.public_subnets) > 0 ? 1 : 0

  route_table_id         = aws_route_table.public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this[0].id
}

resource "aws_route_table_association" "public" {
  for_each = var.public_subnets

  subnet_id      = aws_subnet.public[each.key].id
  route_table_id = aws_route_table.public[0].id
}

# -----------------------------------------------------------------------------
# NAT GATEWAY
# -----------------------------------------------------------------------------

resource "aws_eip" "nat" {
  count = local.nat_gateway_count

  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-nat-eip-${count.index + 1}"
  })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count = local.nat_gateway_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[local.public_subnet_keys[var.single_nat_gateway ? 0 : count.index]].id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-nat-${count.index + 1}"
  })

  depends_on = [aws_internet_gateway.this]
}

# -----------------------------------------------------------------------------
# PRIVATE SUBNETS
# -----------------------------------------------------------------------------

resource "aws_subnet" "private" {
  for_each = var.private_subnets

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.availability_zone
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name                              = "${local.name_prefix}-private-${each.key}"
    Type                              = "private"
    "kubernetes.io/role/internal-elb" = "1"
  })
}

resource "aws_route_table" "private" {
  for_each = var.single_nat_gateway ? toset(["single"]) : toset(keys(var.private_subnets))

  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-private-rt-${each.key}"
  })
}

resource "aws_route" "private_nat" {
  for_each = var.enable_nat_gateway ? (var.single_nat_gateway ? toset(["single"]) : toset(keys(var.private_subnets))) : toset([])

  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = var.single_nat_gateway ? aws_nat_gateway.this[0].id : aws_nat_gateway.this[index(keys(var.private_subnets), each.key)].id
}

resource "aws_route_table_association" "private" {
  for_each = var.private_subnets

  subnet_id      = aws_subnet.private[each.key].id
  route_table_id = var.single_nat_gateway ? aws_route_table.private["single"].id : aws_route_table.private[each.key].id
}

# -----------------------------------------------------------------------------
# VPC FLOW LOGS (SOC 2 CC7.2)
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name              = "/aws/vpc/${local.name_prefix}/flow-logs"
  retention_in_days = var.flow_logs_retention_days
  kms_key_id        = var.kms_key_arn

  tags = local.common_tags
}

resource "aws_iam_role" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name = "${local.name_prefix}-flow-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "vpc-flow-logs.amazonaws.com"
        }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name = "${local.name_prefix}-flow-logs-policy"
  role = aws_iam_role.flow_logs[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams"
        ]
        Effect   = "Allow"
        Resource = "${aws_cloudwatch_log_group.flow_logs[0].arn}:*"
      }
    ]
  })
}

resource "aws_flow_log" "this" {
  count = var.enable_flow_logs ? 1 : 0

  vpc_id                   = aws_vpc.this.id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow_logs[0].arn
  iam_role_arn             = aws_iam_role.flow_logs[0].arn
  max_aggregation_interval = 60

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-flow-log"
  })
}

# -----------------------------------------------------------------------------
# VPC ENDPOINTS (SOC 2 CC6.6 - Private Access)
# -----------------------------------------------------------------------------

resource "aws_security_group" "vpc_endpoints" {
  count = var.enable_vpc_endpoints ? 1 : 0

  name        = "${local.name_prefix}-vpc-endpoints-sg"
  description = "Security group for VPC endpoints"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "HTTPS to VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-vpc-endpoints-sg"
  })
}

# S3 Gateway Endpoint (free)
resource "aws_vpc_endpoint" "s3" {
  count = var.enable_vpc_endpoints ? 1 : 0

  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = concat(
    length(var.public_subnets) > 0 ? [aws_route_table.public[0].id] : [],
    [for rt in aws_route_table.private : rt.id]
  )

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-s3-endpoint"
  })
}

# ECR API Interface Endpoint
resource "aws_vpc_endpoint" "ecr_api" {
  count = var.enable_vpc_endpoints && length(var.private_subnets) > 0 ? 1 : 0

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = [for s in aws_subnet.private : s.id]
  security_group_ids = [aws_security_group.vpc_endpoints[0].id]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-ecr-api-endpoint"
  })
}

# ECR DKR Interface Endpoint
resource "aws_vpc_endpoint" "ecr_dkr" {
  count = var.enable_vpc_endpoints && length(var.private_subnets) > 0 ? 1 : 0

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = [for s in aws_subnet.private : s.id]
  security_group_ids = [aws_security_group.vpc_endpoints[0].id]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-ecr-dkr-endpoint"
  })
}

# CloudWatch Logs Interface Endpoint
resource "aws_vpc_endpoint" "logs" {
  count = var.enable_vpc_endpoints && length(var.private_subnets) > 0 ? 1 : 0

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.logs"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = [for s in aws_subnet.private : s.id]
  security_group_ids = [aws_security_group.vpc_endpoints[0].id]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-logs-endpoint"
  })
}

# SSM Interface Endpoint (for Session Manager)
resource "aws_vpc_endpoint" "ssm" {
  count = var.enable_vpc_endpoints && var.enable_optional_vpc_endpoints && length(var.private_subnets) > 0 ? 1 : 0

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.ssm"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = [for s in aws_subnet.private : s.id]
  security_group_ids = [aws_security_group.vpc_endpoints[0].id]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-ssm-endpoint"
  })
}

# SSM Messages Interface Endpoint
resource "aws_vpc_endpoint" "ssm_messages" {
  count = var.enable_vpc_endpoints && var.enable_optional_vpc_endpoints && length(var.private_subnets) > 0 ? 1 : 0

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = [for s in aws_subnet.private : s.id]
  security_group_ids = [aws_security_group.vpc_endpoints[0].id]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-ssm-messages-endpoint"
  })
}

# EC2 Messages Interface Endpoint
resource "aws_vpc_endpoint" "ec2_messages" {
  count = var.enable_vpc_endpoints && var.enable_optional_vpc_endpoints && length(var.private_subnets) > 0 ? 1 : 0

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.ec2messages"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = [for s in aws_subnet.private : s.id]
  security_group_ids = [aws_security_group.vpc_endpoints[0].id]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-ec2-messages-endpoint"
  })
}

# Secrets Manager Interface Endpoint
resource "aws_vpc_endpoint" "secretsmanager" {
  count = var.enable_vpc_endpoints && length(var.private_subnets) > 0 ? 1 : 0

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = [for s in aws_subnet.private : s.id]
  security_group_ids = [aws_security_group.vpc_endpoints[0].id]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-secretsmanager-endpoint"
  })
}

# SES Interface Endpoint (email sending)
resource "aws_vpc_endpoint" "ses" {
  count = var.enable_vpc_endpoints && var.enable_optional_vpc_endpoints && length(var.private_subnets) > 0 ? 1 : 0

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.email-smtp"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = [for s in aws_subnet.private : s.id]
  security_group_ids = [aws_security_group.vpc_endpoints[0].id]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-ses-endpoint"
  })
}

# SNS Interface Endpoint
resource "aws_vpc_endpoint" "sns" {
  count = var.enable_vpc_endpoints && var.enable_optional_vpc_endpoints && length(var.private_subnets) > 0 ? 1 : 0

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.sns"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = [for s in aws_subnet.private : s.id]
  security_group_ids = [aws_security_group.vpc_endpoints[0].id]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-sns-endpoint"
  })
}

# STS Interface Endpoint (needed for OIDC/IAM role assumption from tasks)
resource "aws_vpc_endpoint" "sts" {
  count = var.enable_vpc_endpoints && var.enable_optional_vpc_endpoints && length(var.private_subnets) > 0 ? 1 : 0

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.sts"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = [for s in aws_subnet.private : s.id]
  security_group_ids = [aws_security_group.vpc_endpoints[0].id]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-sts-endpoint"
  })
}
