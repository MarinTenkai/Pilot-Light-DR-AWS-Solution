#############################################################################
############################ Database (RDS PostgreSQL) #######################
#############################################################################

variable "db_engine_version" {
  description = "Versión de PostgreSQL (si es null, AWS selecciona la default de la región)"
  type        = string
  default     = "17.6"
}

variable "db_name" {
  type    = string
  default = "appdb"
}

variable "db_username" {
  type    = string
  default = "appuser"
}

variable "db_port" {
  type    = number
  default = 5432
}

variable "db_allocated_storage" {
  type    = number
  default = 20
}

variable "db_instance_class_primary" {
  type    = string
  default = "db.t3.micro"
}

variable "db_instance_class_secondary" {
  type    = string
  default = "db.t3.micro"
}

variable "db_backup_retention_days" {
  type    = number
  default = 1
}

variable "db_deletion_protection" {
  type    = bool
  default = false
}

# DNS privado estable para DB (recomendado)
variable "db_private_zone_name" {
  description = "Private Hosted Zone para resolver DB desde ambas VPCs"
  type        = string
  default     = "pilotlight.internal"
}

variable "db_record_name" {
  description = "Nombre del record writer (ej: db => db.pilotlight.internal)"
  type        = string
  default     = "db"
}

#############################################################################
############################ RDS + Private DNS ##############################
#############################################################################

resource "random_password" "db_master" {
  length  = 24
  upper   = true
  lower   = true
  special = true
  # Lista de caracteres especiales permitidos (NO incluir / @ " ni espacio)
  override_special = "!#$%&*()-_+=.,:;?[]{}^~|`"
}

# KMS para RDS/Secrets (uno por región)
resource "aws_kms_key" "rds_primary" {
  provider                = aws.primary
  description             = "${terraform.workspace} RDS key (primary)"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = merge(local.common_tags, local.primary_tags, { Tier = "KMS" })
}

resource "aws_kms_key" "rds_secondary" {
  provider                = aws.secondary
  description             = "${terraform.workspace} RDS key (secondary)"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = merge(local.common_tags, local.secondary_tags, { Tier = "KMS" })
}

# sufijo hex aleatorio
resource "random_id" "secret_suffix" {
  byte_length = 4 # 4 bytes -> 8 hex chars; aumenta si quieres más entropía
}

# Secret en primaria con réplica en secundaria (mismo secreto en ambas regiones)
resource "aws_secretsmanager_secret" "db" {
  provider    = aws.primary
  name        = "${terraform.workspace}/rds/postgres-${random_id.secret_suffix.hex}"
  description = "Credenciales y endpoint estable de PostgreSQL"

  kms_key_id = aws_kms_key.rds_primary.arn

  replica {
    region     = var.secondary_region
    kms_key_id = aws_kms_key.rds_secondary.arn
  }

  tags = merge(local.common_tags, { Tier = "Secrets" })
}

resource "aws_secretsmanager_secret_version" "db" {
  provider  = aws.primary
  secret_id = aws_secretsmanager_secret.db.id

  # Host = DNS estable (Route53 privado) => no cambia para la app
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db_master.result
    dbname   = var.db_name
    port     = var.db_port
    host     = "${var.db_record_name}.${var.db_private_zone_name}"
  })
}

# DB Primaria (Multi-AZ)
module "db_primary" {
  source    = "./modules/database"
  providers = { aws = aws.primary }

  name_prefix = terraform.workspace
  role        = "primary"

  db_subnets             = module.network_primary.database_subnets
  vpc_security_group_ids = [module.network_primary.db_sg_id]

  engine_version    = var.db_engine_version
  instance_class    = var.db_instance_class_primary
  allocated_storage = var.db_allocated_storage

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db_master.result
  port     = var.db_port

  multi_az                = true
  backup_retention_period = var.db_backup_retention_days
  deletion_protection     = var.db_deletion_protection

  kms_key_id = aws_kms_key.rds_primary.arn

  is_replica = false

  tags = merge(local.common_tags, local.primary_tags)
}

# Réplica en Secundaria (cross-region)
module "db_secondary" {
  source    = "./modules/database"
  providers = { aws = aws.secondary }

  name_prefix = terraform.workspace
  role        = "secondary"

  db_subnets             = module.network_secondary.database_subnets
  vpc_security_group_ids = [module.network_secondary.db_sg_id]

  engine_version    = var.db_engine_version
  instance_class    = var.db_instance_class_secondary
  allocated_storage = var.db_allocated_storage # (no se usa si is_replica = true)

  port = var.db_port

  multi_az            = false
  deletion_protection = var.db_deletion_protection

  kms_key_id = aws_kms_key.rds_secondary.arn

  is_replica          = true
  replicate_source_db = module.db_primary.db_instance_arn

  tags = merge(local.common_tags, local.secondary_tags)
}

#############################################################################
######################## Private Hosted Zone (DB) ###########################
#############################################################################

# Zona privada (se crea en un sitio, se asocia a ambas VPCs)
resource "aws_route53_zone" "db_private" {
  provider = aws.primary

  name = var.db_private_zone_name

  vpc {
    vpc_id = module.network_primary.vpc_id
  }

  comment = "Private Hosted Zone for DB - ${var.project_name} (${terraform.workspace})"

  tags = merge(local.common_tags, { Tier = "DNS-Private" })
}

# Asociación de la VPC secundaria a la zona privada
resource "aws_route53_zone_association" "db_private_secondary" {
  provider   = aws.secondary
  zone_id    = aws_route53_zone.db_private.zone_id
  vpc_id     = module.network_secondary.vpc_id
  vpc_region = var.secondary_region
}

# Record writer estable: db.pilotlight.internal -> endpoint activo (por defecto primario)
resource "aws_route53_record" "db_writer" {
  provider = aws.primary

  zone_id = aws_route53_zone.db_private.zone_id
  name    = "${var.db_record_name}.${var.db_private_zone_name}"
  type    = "CNAME"
  ttl     = 30

  records = [module.db_primary.db_address]
}
