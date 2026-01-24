output "Environment" {
  value = terraform.workspace
}

output "vpc_id" {
  description = "ID de la VPC primaria"
  value       = module.vpc_primary.vpc_id
}

output "public_subnets" {
  description = "IDs de subnets públicas"
  value       = module.vpc_primary.public_subnets
}

output "private_subnets" {
  description = "IDs de subnets privadas (app)"
  value       = module.vpc_primary.private_subnets
}

output "database_subnets" {
  description = "IDs de subnets privadas (db)"
  value       = module.vpc_primary.database_subnets
}
