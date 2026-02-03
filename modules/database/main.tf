locals {
  identifier        = "${var.name_prefix}-rds-${var.role}"
  subnet_group_name = "${var.name_prefix}-rds-${var.role}-subnets"

  final_snapshot_id = coalesce(
    var.final_snapshot_identifier,
    "${local.identifier}-final"
  )
}

resource "aws_db_subnet_group" "this" {
  name       = local.subnet_group_name
  subnet_ids = var.db_subnets

  tags = merge(var.tags, {
    Name = local.subnet_group_name
    Tier = "Database"
  })
}

############################
# PRIMARY (no replica)
############################
resource "aws_db_instance" "primary" {
  count = var.is_replica ? 0 : 1

  identifier = local.identifier

  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage = var.allocated_storage
  storage_type      = var.storage_type

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = var.vpc_security_group_ids

  port = var.port

  multi_az            = var.multi_az
  publicly_accessible = false

  storage_encrypted = true
  kms_key_id        = var.kms_key_id

  db_name  = var.db_name
  username = var.username
  password = var.password

  backup_retention_period = var.backup_retention_period
  deletion_protection     = var.deletion_protection
  apply_immediately       = var.apply_immediately

  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true

  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : local.final_snapshot_id

  tags = merge(var.tags, {
    Name = local.identifier
    Tier = "Database"
    Role = var.role
  })
}

############################
# REPLICA (cross-region)
############################
resource "aws_db_instance" "replica" {
  count = var.is_replica ? 1 : 0

  identifier = local.identifier

  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  # En read replica normalmente no se especifica storage inicial
  allocated_storage = null
  storage_type      = var.storage_type

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = var.vpc_security_group_ids

  port = var.port

  multi_az            = var.multi_az
  publicly_accessible = false

  storage_encrypted = true
  kms_key_id        = var.kms_key_id

  # Réplica (cross-region)
  replicate_source_db = var.replicate_source_db

  # En réplicas suele ser 0 (no backups en la réplica)
  backup_retention_period = 0
  deletion_protection     = var.deletion_protection
  apply_immediately       = var.apply_immediately

  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true

  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : local.final_snapshot_id

  # IMPORTANTE:
  # si la réplica se PROMUEVE, AWS elimina replicate_source_db.
  # Ignoramos cambios para evitar que Terraform intente “recolgarla”.
  lifecycle {
    ignore_changes = [replicate_source_db]
  }

  tags = merge(var.tags, {
    Name = local.identifier
    Tier = "Database"
    Role = var.role
  })
}
