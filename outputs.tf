#### Outputs Comunes de la Región Primaria y Secundaria ####

output "Environment" {
  value = terraform.workspace
}

#### Outputs de la región primaria ####

output "vpc_id_primary" {
  value = module.network_primary.vpc_id
}

# output "vpc_id_secondary" {
#   value = module.network_secondary.vpc_id
# }

output "public_subnets_primary" {
  value = module.network_primary.public_subnets
}

# output "public_subnets_secondary" {
#   value = module.network_secondary.public_subnets
# }

output "private_subnets_primary" {
  value = module.network_primary.private_subnets
}

# output "private_subnets_secondary" {
#   value = module.network_secondary.private_subnets
# }

output "database_subnets_primary" {
  value = module.network_primary.database_subnets
}

# output "database_subnets_secondary" {
#   value = module.network_secondary.database_subnets
# }

output "flow_logs_s3_destination_arn_primary" {
  value = module.network_primary.flow_logs_s3_destination_arn
}

# output "flow_logs_s3_destination_arn_secondary" {
#   value = module.network_secondary.flow_logs_s3_destination_arn
# }

output "frontend_alb_dns_name_primary" {
  value       = module.alb_frontend_primary.dns_name
  description = "DNS público del ALB"
}

output "frontend_asg_name_primary" {
  value       = module.autoscaling_frontend_primary.autoscaling_group_name
  description = "Nombre del ASG del frontend"
}

output "backend_alb_dns_name_primary" {
  value       = module.alb_backend_primary.dns_name
  description = "DNS del ALB interno del backend (solo se puede resolver dentro de la VPC)"
}

output "rds_postgresql_endpoint" {
  description = "Endpoint DNS del RDS PostgreSQL"
  value       = aws_db_instance.postgresql.endpoint
}

output "rds_postgresql_port" {
  description = "Puerto del RDS PostgreSQL"
  value       = aws_db_instance.postgresql.port
}

output "rds_postgresql_db_name" {
  description = "Nombre de la DB"
  value       = var.postgresql_db_name
}

output "rds_postgres_master_secret_arn" {
  description = "Secret ARN (username/password) creado por RDS en Secrets Manager"
  value       = aws_db_instance.postgresql.master_user_secret[0].secret_arn
  sensitive   = true
}
