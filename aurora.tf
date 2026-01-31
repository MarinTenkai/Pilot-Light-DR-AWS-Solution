## Aurora - Cluster

/*

resource "aws_rds_cluster" "aurora" {
  cluster_identifier = "${terraform.workspace}-aurora"

  engine        = var.aurora_engine
  database_name = var.aurora_database_name

  master_username             = var.aurora_master_username
  manage_master_user_password = true

  # Usa el DB subnet group creado (database_subnets)
  db_subnet_group_name   = module.vpc_primary.database_subnet_group_name
  vpc_security_group_ids = [aws_security_group.aurora_sg.id]

  storage_encrypted       = true
  backup_retention_period = var.aurora_backup_retention_period
  deletion_protection     = var.aurora_deletion_protection
  skip_final_snapshot     = var.aurora_skip_final_snapshot
  apply_immediately       = true

  tags = merge(local.common_tags, {
    name = "${terraform.workspace}-aurora"
    tier = "Database"
  })
}

## Aurora - Writer (AZ1)

resource "aws_rds_cluster_instance" "aurora_writer" {
  identifier         = "${terraform.workspace}-aurora-writer"
  cluster_identifier = aws_rds_cluster.aurora.id

  instance_class = var.aurora_instance_class
  engine         = aws_rds_cluster.aurora.engine

  publicly_accessible = false
  availability_zone   = local.azs[0]

  tags = merge(local.common_tags, {
    name = "${terraform.workspace}-aurora-writer"
    tier = "Database"
    role = "writer"
  })
}

## Aurora - Reader/Replica (AZ2)
resource "aws_rds_cluster_instance" "aurora_reader" {
  identifier         = "${terraform.workspace}-aurora-reader"
  cluster_identifier = aws_rds_cluster.aurora.id

  instance_class = var.aurora_instance_class
  engine         = aws_rds_cluster.aurora.engine

  publicly_accessible = false
  availability_zone   = local.azs[1]

  # Para favorecer que el writer siga siendo el writer en failover
  promotion_tier = 2

  depends_on = [aws_rds_cluster_instance.aurora_writer]

  tags = merge(local.common_tags, {
    name = "${terraform.workspace}-aurora-reader"
    tier = "Database"
    role = "reader"
  })
}

*/

## AURORA DATABASE ###

/*

variable "aurora_engine" {
  description = "Motor Aurora (aurora-postgresql o aurora-mysql)"
  type        = string
  default     = "aurora-postgresql"
}

variable "aurora_port" {
  description = "Puerto de la BD (5432 para aurora-postgresql, 3306 para aurora-mysql)"
  type        = number
  default     = 5432
}

variable "aurora_database_name" {
  description = "Nombre de la base de datos inicial"
  type        = string
  default     = "appdb"
}

variable "aurora_master_username" {
  description = "Usuario master (la password se gestionará en Secrets Manager)"
  type        = string
  default     = "dbadmin"
}

variable "aurora_instance_class" {
  description = "Clase de instancia Aurora"
  type        = string
  default     = "db.t3.medium"
}

variable "aurora_backup_retention_period" {
  description = "Días de retención de backups"
  type        = number
  default     = 1
}

variable "aurora_deletion_protection" {
  description = "Protección contra borrado"
  type        = bool
  default     = false
}

variable "aurora_skip_final_snapshot" {
  description = "Evitar snapshot final al destruir (para labs/dev)"
  type        = bool
  default     = true
}

variable "aurora_with_express_configuration" {
  description = "Requerido para las cuentas 'free plan'"
  type        = bool
  default     = true
}

*/
