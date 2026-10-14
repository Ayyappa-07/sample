# =============================================================================
# AWS RDS MODULE
# =============================================================================
# Managed relational database with encryption, multi-AZ, automated backups
# SOC 2 Controls: CC6.1 (access control), CC6.6 (encryption at rest),
#                 CC6.7 (encryption in transit), CC7.2 (monitoring),
#                 CC9.1 (availability/recovery)
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  name_prefix = var.project_name

  port = coalesce(var.port, var.engine == "postgres" ? 5432 : 3306)

  cloudwatch_log_exports = coalesce(var.cloudwatch_log_exports, {
    postgres = ["postgresql", "upgrade"]
    mysql    = ["audit", "error", "general", "slowquery"]
    mariadb  = ["audit", "error", "general", "slowquery"]
  }[var.engine])

  final_snapshot_identifier = coalesce(
    var.final_snapshot_identifier,
    "${local.name_prefix}-rds-final"
  )

  common_tags = merge(var.tags, {
    Module = "aws/rds"
  })
}

# -----------------------------------------------------------------------------
# CLOUDWATCH LOG GROUPS (one per RDS log export)
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "rds" {
  for_each = toset(local.cloudwatch_log_exports)

  name              = "/aws/rds/instance/${local.name_prefix}-rds/${each.value}"
  retention_in_days = var.log_retention_days

  lifecycle {
    # Keep RDS logs safe if an export is removed; use terraform state rm
    # to intentionally remove a log group from Terraform management.
    prevent_destroy = true
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-rds-${each.value}-logs"
  })
}

moved {
  from = aws_cloudwatch_log_group.postgresql
  to   = aws_cloudwatch_log_group.rds["postgresql"]
}

# -----------------------------------------------------------------------------
# SUBNET GROUP (SOC 2 CC6.1 - Network Isolation)
# -----------------------------------------------------------------------------

resource "aws_db_subnet_group" "this" {
  name        = "${local.name_prefix}-rds"
  description = "Subnet group for ${local.name_prefix} RDS"
  subnet_ids  = var.subnet_ids

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-rds-subnet-group"
  })
}

# -----------------------------------------------------------------------------
# SECURITY GROUP (SOC 2 CC6.1 - Least Privilege Network Access)
# -----------------------------------------------------------------------------

resource "aws_security_group" "this" {
  name        = "${local.name_prefix}-rds"
  description = "Security group for ${local.name_prefix} RDS instance"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-rds-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "database" {
  count = length(var.allowed_security_group_ids)

  security_group_id            = aws_security_group.this.id
  description                  = "Allow database access from authorized security groups"
  from_port                    = local.port
  to_port                      = local.port
  ip_protocol                  = "tcp"
  referenced_security_group_id = var.allowed_security_group_ids[count.index]
}

resource "aws_vpc_security_group_ingress_rule" "cidr" {
  for_each = toset(var.allowed_cidr_blocks)

  security_group_id = aws_security_group.this.id
  description       = "Allow database access from authorized CIDR"
  from_port         = local.port
  to_port           = local.port
  ip_protocol       = "tcp"
  cidr_ipv4         = each.value
}

# -----------------------------------------------------------------------------
# PARAMETER GROUP (SOC 2 CC6.7 - Enforce TLS)
# -----------------------------------------------------------------------------

resource "aws_db_parameter_group" "this" {
  count = var.create_parameter_group ? 1 : 0

  # name_prefix (not a static name): the group is create_before_destroy — on a
  # family change (e.g. postgres16 -> postgres17) the replacement is created
  # BEFORE the old one is destroyed, and a static name collides with itself
  # (DBParameterGroupAlreadyExists). The random suffix makes replacement safe.
  name_prefix = "${local.name_prefix}-rds-"
  family      = var.parameter_group_family
  description = "Parameter group for ${local.name_prefix} RDS"

  dynamic "parameter" {
    for_each = var.engine == "postgres" ? [1] : []
    content {
      name         = "rds.force_ssl"
      value        = "1"
      apply_method = "pending-reboot"
    }
  }

  dynamic "parameter" {
    for_each = contains(["mysql", "mariadb"], var.engine) ? [1] : []
    content {
      name         = "require_secure_transport"
      value        = "ON"
      apply_method = "pending-reboot"
    }
  }

  dynamic "parameter" {
    for_each = var.engine == "postgres" ? [1] : []
    content {
      name  = "log_connections"
      value = "1"
    }
  }

  dynamic "parameter" {
    for_each = var.engine == "postgres" ? [1] : []
    content {
      name  = "log_disconnections"
      value = "1"
    }
  }

  dynamic "parameter" {
    for_each = var.engine == "postgres" ? [1] : []
    content {
      name  = "log_statement"
      value = "ddl"
    }
  }

  dynamic "parameter" {
    for_each = var.additional_parameters
    content {
      name         = parameter.value.name
      value        = parameter.value.value
      apply_method = lookup(parameter.value, "apply_method", "immediate")
    }
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-rds-params"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# RDS INSTANCE (SOC 2 CC6.6, CC9.1 - Encryption + High Availability)
# -----------------------------------------------------------------------------

resource "aws_db_instance" "this" {
  identifier = "${local.name_prefix}-rds"

  engine         = var.engine
  engine_version = var.engine_version
  instance_class = var.instance_class
  port           = local.port

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = var.storage_type
  iops                  = var.storage_type == "io1" || var.storage_type == "io2" ? var.iops : null

  db_name  = var.database_name
  username = var.master_username
  password = var.manage_master_user_password ? null : var.master_password

  manage_master_user_password   = var.manage_master_user_password
  master_user_secret_kms_key_id = var.manage_master_user_password ? var.kms_key_arn : null

  multi_az               = var.multi_az
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  publicly_accessible    = false

  # Encryption (SOC 2 CC6.6)
  storage_encrypted = true
  kms_key_id        = var.kms_key_arn

  # Backups (SOC 2 CC9.1)
  backup_retention_period   = var.backup_retention_period
  backup_window             = var.backup_window
  maintenance_window        = var.maintenance_window
  copy_tags_to_snapshot     = true
  delete_automated_backups  = false
  final_snapshot_identifier = local.final_snapshot_identifier
  skip_final_snapshot       = var.skip_final_snapshot

  # Monitoring (SOC 2 CC7.2)
  enabled_cloudwatch_logs_exports = local.cloudwatch_log_exports
  monitoring_interval             = var.enhanced_monitoring_interval
  monitoring_role_arn             = var.enhanced_monitoring_interval > 0 ? aws_iam_role.monitoring[0].arn : null

  # Performance Insights (SOC 2 CC7.2)
  performance_insights_enabled          = var.enable_performance_insights
  performance_insights_kms_key_id       = var.enable_performance_insights ? var.kms_key_arn : null
  performance_insights_retention_period = var.enable_performance_insights ? var.performance_insights_retention : null

  # Security
  iam_database_authentication_enabled = var.enable_iam_auth
  ca_cert_identifier                  = var.ca_cert_identifier
  parameter_group_name                = var.create_parameter_group ? aws_db_parameter_group.this[0].name : null

  # Protection
  deletion_protection = var.deletion_protection

  auto_minor_version_upgrade = var.auto_minor_version_upgrade
  apply_immediately          = var.apply_immediately

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-rds"
  })
}

# -----------------------------------------------------------------------------
# READ REPLICA (SOC 2 CC9.1 - Availability)
# -----------------------------------------------------------------------------

resource "aws_db_instance" "replica" {
  count = var.enable_read_replica ? 1 : 0

  identifier          = "${local.name_prefix}-rds-replica"
  replicate_source_db = aws_db_instance.this.identifier
  instance_class      = var.replica_instance_class != "" ? var.replica_instance_class : var.instance_class

  publicly_accessible    = false
  vpc_security_group_ids = [aws_security_group.this.id]

  storage_encrypted = true
  kms_key_id        = var.kms_key_arn

  monitoring_interval = var.enhanced_monitoring_interval
  monitoring_role_arn = var.enhanced_monitoring_interval > 0 ? aws_iam_role.monitoring[0].arn : null

  performance_insights_enabled          = var.enable_performance_insights
  performance_insights_kms_key_id       = var.enable_performance_insights ? var.kms_key_arn : null
  performance_insights_retention_period = var.enable_performance_insights ? var.performance_insights_retention : null

  auto_minor_version_upgrade = var.auto_minor_version_upgrade
  skip_final_snapshot        = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-rds-replica"
  })
}

# -----------------------------------------------------------------------------
# ENHANCED MONITORING IAM ROLE (SOC 2 CC7.2)
# -----------------------------------------------------------------------------

resource "aws_iam_role" "monitoring" {
  count = var.enhanced_monitoring_interval > 0 ? 1 : 0

  name = "${local.name_prefix}-rds-monitoring"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "monitoring.rds.amazonaws.com"
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "monitoring" {
  count = var.enhanced_monitoring_interval > 0 ? 1 : 0

  role       = aws_iam_role.monitoring[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# -----------------------------------------------------------------------------
# CLOUDWATCH ALARMS (SOC 2 CC7.2 - Monitoring)
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "cpu" {
  count = var.enable_alarms ? 1 : 0

  alarm_name          = "${local.name_prefix}-rds-high-cpu"
  alarm_description   = "RDS CPU utilization exceeds ${var.alarm_cpu_threshold}%"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = var.alarm_cpu_threshold
  treat_missing_data  = "breaching"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.this.identifier
  }

  alarm_actions = var.alarm_sns_topic_arns
  ok_actions    = var.alarm_sns_topic_arns

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "free_storage" {
  count = var.enable_alarms ? 1 : 0

  alarm_name          = "${local.name_prefix}-rds-low-storage"
  alarm_description   = "RDS free storage below ${var.alarm_free_storage_threshold} bytes"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = var.alarm_free_storage_threshold
  treat_missing_data  = "breaching"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.this.identifier
  }

  alarm_actions = var.alarm_sns_topic_arns
  ok_actions    = var.alarm_sns_topic_arns

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "freeable_memory" {
  count = var.enable_alarms ? 1 : 0

  alarm_name          = "${local.name_prefix}-rds-low-memory"
  alarm_description   = "RDS freeable memory below ${var.alarm_freeable_memory_threshold} bytes"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "FreeableMemory"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = var.alarm_freeable_memory_threshold
  treat_missing_data  = "breaching"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.this.identifier
  }

  alarm_actions = var.alarm_sns_topic_arns
  ok_actions    = var.alarm_sns_topic_arns

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "swap_usage" {
  count = var.enable_alarms ? 1 : 0

  alarm_name          = "${local.name_prefix}-rds-high-swap"
  alarm_description   = "RDS swap usage exceeds 128 MB"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "SwapUsage"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 134217728
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.this.identifier
  }

  alarm_actions = var.alarm_sns_topic_arns
  ok_actions    = var.alarm_sns_topic_arns

  tags = local.common_tags
}
resource "aws_cloudwatch_metric_alarm" "connections" {
  count = var.enable_alarms ? 1 : 0

  alarm_name          = "${local.name_prefix}-rds-high-connections"
  alarm_description   = "RDS connection count exceeds ${var.alarm_connections_threshold}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = var.alarm_connections_threshold
  treat_missing_data  = "breaching"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.this.identifier
  }

  alarm_actions = var.alarm_sns_topic_arns
  ok_actions    = var.alarm_sns_topic_arns

  tags = local.common_tags
}
