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
