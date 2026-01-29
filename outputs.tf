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

output "flow_logs_s3_destination_arn" {
  description = "ARN destino para VPC Flow Logs (bucket + prefix)"
  value       = "${module.s3-bucket.s3_bucket_arn}/${var.flow_logs_s3_prefix}"
}

output "debug_policy" {
  value = aws_s3_bucket_policy.flow_logs.policy
}

output "frontend_alb_dns_name" {
  value       = module.alb.dns_name
  description = "DNS público del ALB"
}

output "frontend_asg_name" {
  value       = module.autoscaling.autoscaling_group_name
  description = "Nombre del ASG del frontend"
}
