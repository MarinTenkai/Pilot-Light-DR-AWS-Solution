output "vpc_id" {
  value = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  value = module.vpc.vpc_cidr_block
}

output "public_subnets" {
  value = module.vpc.public_subnets
}

output "private_subnets" {
  value = module.vpc.private_subnets
}

output "database_subnets" {
  value = module.vpc.database_subnets
}

output "flow_logs_s3_destination_arn" {
  value = "${module.s3_bucket_flow_logs.s3_bucket_arn}/${var.flow_logs_s3_prefix}"
}

# IDs de los Security Groups creados por el módulo

output "alb_frontend_sg_id" {
  value = aws_security_group.alb_frontend_sg.id
}

output "frontend_sg_id" {
  value = aws_security_group.frontend_sg.id
}

output "alb_backend_sg_id" {
  value = aws_security_group.alb_backend_sg.id
}

output "backend_sg_id" {
  value = aws_security_group.backend_sg.id
}

output "db_sg_id" {
  value = aws_security_group.db_sg.id
}

output "vpce_sg_id" {
  value = aws_security_group.vpce_sg.id
}

output "app_instance_sg_ids" {
  value = {
    frontend = aws_security_group.frontend_sg.id
    backend  = aws_security_group.backend_sg.id
  }
}
