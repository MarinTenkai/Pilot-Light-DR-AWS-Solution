#### Outputs Comunes de la región primaria y secundaria ####

output "flow_logs_s3_destination_arn" {
  description = "ARN destino para VPC Flow Logs (bucket + prefix)"
  value       = "${module.s3-bucket.s3_bucket_arn}/${var.flow_logs_s3_prefix}"
}

output "Environment" {
  value = terraform.workspace
}

#### Outputs de la región primaria ####

output "vpc_primary_id" {
  description = "ID de la VPC primaria"
  value       = module.vpc_primary.vpc_id
}

output "public_primary_subnets" {
  description = "IDs de subnets públicas"
  value       = module.vpc_primary.public_subnets
}

output "private_primary_subnets" {
  description = "IDs de subnets privadas (app)"
  value       = module.vpc_primary.private_subnets
}

output "database_primary_subnets" {
  description = "IDs de subnets privadas (db)"
  value       = module.vpc_primary.database_subnets
}

output "frontend_primary_alb_dns_name" {
  value       = module.alb.dns_name
  description = "DNS público del ALB"
}

output "frontend_primary_asg_name" {
  value       = module.autoscaling.autoscaling_group_name
  description = "Nombre del ASG del frontend"
}

output "backend_alb_dns_name" {
  value       = module.backend_alb.dns_name
  description = "DNS del ALB interno del backend (solo se puede resolver dentro de la VPC)"
}
