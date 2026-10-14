# =============================================================================
# AWS ELASTICACHE REDIS MODULE
# =============================================================================
# Managed Redis cluster for session store and caching (Next.js app)
# Features: replication, encryption at rest/transit, AUTH token, CloudWatch alarms
# =============================================================================

locals {
  name_prefix = var.project_name

  automatic_failover_enabled = var.num_cache_clusters >= 2
  multi_az_enabled           = var.num_cache_clusters >= 2

  common_tags = merge(var.tags, {
    Module = "aws/elasticache"
  })
}

# -----------------------------------------------------------------------------
# AUTH TOKEN (Secrets Manager)
# -----------------------------------------------------------------------------

resource "random_password" "auth_token" {
  length           = 64
  special          = true
  override_special = "!&#$^<>-"
}

resource "aws_secretsmanager_secret" "auth_token" {
  name        = "${local.name_prefix}-redis-auth-token"
  description = "Redis AUTH token for ${local.name_prefix}"
  kms_key_id  = var.kms_key_arn

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-redis-auth-token"
  })
}

resource "aws_secretsmanager_secret_version" "auth_token" {
  secret_id     = aws_secretsmanager_secret.auth_token.id
  secret_string = random_password.auth_token.result
}

# -----------------------------------------------------------------------------
# SUBNET GROUP (Private Subnets)
# -----------------------------------------------------------------------------

resource "aws_elasticache_subnet_group" "this" {
  name        = "${local.name_prefix}-redis"
  description = "Subnet group for ${local.name_prefix} Redis cluster"
  subnet_ids  = var.subnet_ids

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-redis-subnet-group"
  })
}

# -----------------------------------------------------------------------------
# SECURITY GROUP
# -----------------------------------------------------------------------------

resource "aws_security_group" "this" {
  name        = "${local.name_prefix}-redis"
  description = "Security group for ${local.name_prefix} Redis cluster"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-redis-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "redis" {
  count = length(var.allowed_security_group_ids)

  security_group_id            = aws_security_group.this.id
  description                  = "Allow Redis access from authorized security groups"
  from_port                    = var.port
  to_port                      = var.port
  ip_protocol                  = "tcp"
  referenced_security_group_id = var.allowed_security_group_ids[count.index]
}

# -----------------------------------------------------------------------------
# PARAMETER GROUP (maxmemory-policy = allkeys-lru)
# -----------------------------------------------------------------------------

resource "aws_elasticache_parameter_group" "this" {
  name        = "${local.name_prefix}-redis"
  family      = var.parameter_group_family
  description = "Parameter group for ${local.name_prefix} Redis"

  parameter {
    name  = "maxmemory-policy"
    value = "allkeys-lru"
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-redis-params"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# REPLICATION GROUP (Redis Cluster)
# -----------------------------------------------------------------------------

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = "${local.name_prefix}-redis"
  description          = "Redis replication group for ${local.name_prefix}"

  engine               = "redis"
  engine_version       = var.engine_version
  node_type            = var.node_type
  port                 = var.port
  parameter_group_name = aws_elasticache_parameter_group.this.name
  subnet_group_name    = aws_elasticache_subnet_group.this.name
  security_group_ids   = [aws_security_group.this.id]

  num_cache_clusters = var.num_cache_clusters

  # High availability
  automatic_failover_enabled = local.automatic_failover_enabled
  multi_az_enabled           = local.multi_az_enabled

  # Encryption in transit (AUTH token requires transit encryption)
  transit_encryption_enabled = var.transit_encryption_enabled
  auth_token                 = random_password.auth_token.result

  # Encryption at rest (KMS)
  at_rest_encryption_enabled = var.at_rest_encryption_enabled
  kms_key_id                 = var.kms_key_arn

  # Backups / snapshots
  snapshot_retention_limit = var.snapshot_retention_limit
  snapshot_window          = var.snapshot_retention_limit > 0 ? var.snapshot_window : null
  maintenance_window       = var.maintenance_window

  # Prevent accidental changes to AUTH token from triggering replacement
  lifecycle {
    ignore_changes = [auth_token]
  }

  apply_immediately = false

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-redis"
  })
}

# -----------------------------------------------------------------------------
# CLOUDWATCH ALARMS
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "cpu" {
  for_each = length(var.alarm_sns_topic_arns) > 0 ? toset([
    for i in range(1, var.num_cache_clusters + 1) : format("%03d", i)
  ]) : toset([])

  alarm_name          = "${local.name_prefix}-redis-high-cpu-${each.key}"
  alarm_description   = "Redis EngineCPUUtilization exceeds 80% on node ${each.key}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "EngineCPUUtilization"
  namespace           = "AWS/ElastiCache"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  treat_missing_data  = "breaching"

  dimensions = {
    CacheClusterId = "${aws_elasticache_replication_group.this.id}-${each.key}"
  }

  alarm_actions = var.alarm_sns_topic_arns
  ok_actions    = var.alarm_sns_topic_arns

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "memory" {
  for_each = length(var.alarm_sns_topic_arns) > 0 ? toset([
    for i in range(1, var.num_cache_clusters + 1) : format("%03d", i)
  ]) : toset([])

  alarm_name          = "${local.name_prefix}-redis-high-memory-${each.key}"
  alarm_description   = "Redis DatabaseMemoryUsagePercentage exceeds 80% on node ${each.key}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "DatabaseMemoryUsagePercentage"
  namespace           = "AWS/ElastiCache"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  treat_missing_data  = "breaching"

  dimensions = {
    CacheClusterId = "${aws_elasticache_replication_group.this.id}-${each.key}"
  }

  alarm_actions = var.alarm_sns_topic_arns
  ok_actions    = var.alarm_sns_topic_arns

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "connections" {
  for_each = length(var.alarm_sns_topic_arns) > 0 ? toset([
    for i in range(1, var.num_cache_clusters + 1) : format("%03d", i)
  ]) : toset([])

  alarm_name          = "${local.name_prefix}-redis-high-connections-${each.key}"
  alarm_description   = "Redis CurrConnections exceeds 5000 on node ${each.key}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CurrConnections"
  namespace           = "AWS/ElastiCache"
  period              = 300
  statistic           = "Average"
  threshold           = 5000
  treat_missing_data  = "breaching"

  dimensions = {
    CacheClusterId = "${aws_elasticache_replication_group.this.id}-${each.key}"
  }

  alarm_actions = var.alarm_sns_topic_arns
  ok_actions    = var.alarm_sns_topic_arns

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "evictions" {
  for_each = length(var.alarm_sns_topic_arns) > 0 ? toset([
    for i in range(1, var.num_cache_clusters + 1) : format("%03d", i)
  ]) : toset([])

  alarm_name          = "${local.name_prefix}-redis-evictions-${each.key}"
  alarm_description   = "Redis Evictions detected — memory pressure causing key eviction on node ${each.key}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Evictions"
  namespace           = "AWS/ElastiCache"
  period              = 300
  statistic           = "Sum"
  threshold           = 100
  treat_missing_data  = "notBreaching"

  dimensions = {
    CacheClusterId = "${aws_elasticache_replication_group.this.id}-${each.key}"
  }

  alarm_actions = var.alarm_sns_topic_arns
  ok_actions    = var.alarm_sns_topic_arns

  tags = local.common_tags
}
