#### Comunes ####
#################

output "Environment" {
  value = terraform.workspace
}

output "dr_failover_sns_topic_arn" {
  value       = try(aws_sns_topic.dr_failover[0].arn, null)
  description = "SNS Topic ARN para notificaciones de FAILOVER"
}

output "dr_failback_sns_topic_arn" {
  value       = try(aws_sns_topic.dr_failback[0].arn, null)
  description = "SNS Topic ARN para notificaciones de FAILBACK"
}

#################
#### Network ####
#################

output "vpc_id_primary" {
  value = module.network_primary.vpc_id
}

output "vpc_id_secondary" {
  value = module.network_secondary.vpc_id
}

output "public_subnets_primary" {
  value = module.network_primary.public_subnets
}

output "public_subnets_secondary" {
  value = module.network_secondary.public_subnets
}

output "private_subnets_primary" {
  value = module.network_primary.private_subnets
}

output "private_subnets_secondary" {
  value = module.network_secondary.private_subnets
}

output "database_subnets_primary" {
  value = module.network_primary.database_subnets
}

output "database_subnets_secondary" {
  value = module.network_secondary.database_subnets
}

####################################################
#### Bucket S3 para logs de tráfico de las VPCs ####
####################################################

output "flow_logs_s3_destination_arn_primary" {
  value = module.network_primary.flow_logs_s3_destination_arn
}

output "flow_logs_s3_destination_arn_secondary" {
  value = module.network_secondary.flow_logs_s3_destination_arn
}

################################
#### Elastic Load Balancers ####
################################

output "frontend_alb_dns_name_primary" {
  value       = module.frontend_primary.alb_dns_name
  description = "DNS público del ALB"
}

output "frontend_alb_dns_name_secondary" {
  value       = module.frontend_secondary.alb_dns_name
  description = "DNS público del ALB"
}

output "backend_alb_dns_name_primary" {
  value       = module.backend_primary.alb_dns_name
  description = "DNS del ALB interno del backend (solo se puede resolver dentro de la VPC)"
}

output "backend_alb_dns_name_secondary" {
  value       = module.backend_secondary.alb_dns_name
  description = "DNS del ALB interno del backend (solo se puede resolver dentro de la VPC)"
}

#############################
#### Auto Scaling Groups ####
#############################

output "frontend_asg_name_primary" {
  value       = module.frontend_primary.asg_name
  description = "Nombre del ASG del frontend"
}

output "frontend_asg_name_secondary" {
  value       = module.frontend_secondary.asg_name
  description = "Nombre del ASG del frontend"
}

output "backend_asg_name_primary" {
  value       = module.backend_primary.asg_name
  description = "Nombre del ASG del frontend"
}

output "backend_asg_name_secondary" {
  value       = module.backend_secondary.asg_name
  description = "Nombre del ASG del frontend"
}

##################
#### Route 53 ####
##################

output "route53_zone_name" {
  value       = aws_route53_zone.public.name
  description = "Nombre de la hosted zone creada."
}

output "route53_zone_id" {
  value       = aws_route53_zone.public.zone_id
  description = "ID de la hosted zone creada."
}

output "route53_name_servers" {
  value       = aws_route53_zone.public.name_servers
  description = "Nameservers autoritativos de Route53 (para probar sin dominio comprado)."
}

output "frontend_failover_fqdn" {
  value       = "${var.route53_record_name}.${var.route53_zone_name}"
  description = "FQDN del record con failover."
}

########################
#### RDS POSTGRESQL ####
########################

output "db_writer_fqdn_private" {
  value       = "${var.db_record_name}.${var.db_private_zone_name}"
  description = "Hostname estable (private) del writer DB. La Lambda lo mueve entre regiones."
}

output "db_secret_arn" {
  value       = aws_secretsmanager_secret.db.arn
  description = "Secret (replicado a secundaria) con credenciales + host estable."
}

output "db_primary_endpoint" {
  value = module.db_primary.db_endpoint
}

output "db_secondary_endpoint" {
  value = module.db_secondary.db_endpoint
}
