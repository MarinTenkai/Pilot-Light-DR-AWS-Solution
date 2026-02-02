# ### Recursos de RDS Database ###

# ## Grupos de seguridad, ajustes de red y reglas para RDS PostgresSQL

# # Subnet Group para RDS usando las subnets "database" del módulo VPC

# resource "aws_db_subnet_group" "postgresql" {
#   name       = "${terraform.workspace}j-postgresql-subnet-group"
#   subnet_ids = module.network_primary.database_subnets

#   tags = merge(local.common_tags, local.primary_tags, {
#     name = "${terraform.workspace}-postgresql-subnet-group"
#     tier = "Database"
#   })
# }

# # Grupo de seguridad para RDS
# resource "aws_security_group" "rds_sg" {
#   name        = "${terraform.workspace}-rds-sg"
#   description = "SG para rds: solo accesible desde backend"
#   vpc_id      = module.network_primary.vpc_id

#   tags = merge(local.common_tags, local.primary_tags, {
#     name = "${terraform.workspace}-rds-sg"
#     tier = "Database"
#   })
# }

# # Regla Backend -> rds (egress necesario porque backend_sg es restrictivo)
# resource "aws_security_group_rule" "backend_egress_to_rds" {
#   type                     = "egress"
#   security_group_id        = module.network_primary.backend_sg_id
#   description              = "Backend hacia rds"
#   from_port                = var.db_port
#   to_port                  = var.db_port
#   protocol                 = "tcp"
#   source_security_group_id = aws_security_group.rds_sg.id
# }

# # Regla rds <- Backend (ingress)
# resource "aws_security_group_rule" "rds_ingress_from_backend" {
#   type                     = "ingress"
#   security_group_id        = aws_security_group.rds_sg.id
#   description              = "Backend hacia rds"
#   from_port                = var.db_port
#   to_port                  = var.db_port
#   protocol                 = "tcp"
#   source_security_group_id = module.network_primary.backend_sg_id
# }

# ## Recursos para RDS PostgresSQL Multi-AZ

# resource "aws_db_instance" "postgresql" {
#   identifier = "${terraform.workspace}-postgresql"

#   engine         = "postgres"
#   instance_class = var.postgresql_instance_class

#   db_name                     = var.postgresql_db_name
#   username                    = var.postgresql_master_username
#   manage_master_user_password = true
#   port                        = var.db_port

#   #Red/VPC
#   db_subnet_group_name   = aws_db_subnet_group.postgresql.name
#   vpc_security_group_ids = [aws_security_group.rds_sg.id]
#   publicly_accessible    = false

#   # Multi-AZ:
#   multi_az = true

#   # Storage
#   allocated_storage     = var.postgresql_allocated_storage
#   max_allocated_storage = var.postgresql_max_allocated_storage
#   storage_type          = "gp3"
#   storage_encrypted     = true

#   # Operación (modo lab)
#   apply_immediately       = true
#   skip_final_snapshot     = true
#   deletion_protection     = false
#   backup_retention_period = 1

#   tags = merge(local.common_tags, local.primary_tags, {
#     name = "${terraform.workspace}-postgresql"
#     tier = "Database"
#   })
# }
