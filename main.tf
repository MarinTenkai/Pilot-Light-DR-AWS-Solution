module "network_primary" {
  source    = "./modules/network"
  providers = { aws = aws.primary }

  name_prefix = terraform.workspace
  role        = local.network.primary.role

  azs              = local.network.primary.azs
  vpc_cidr         = local.network.primary.vpc_cidr
  public_subnets   = local.network.primary.public_subnets
  private_subnets  = local.network.primary.private_subnets
  database_subnets = local.network.primary.database_subnets

  # comunes
  enable_nat_gateway     = local.vpc_common.enable_nat_gateway
  one_nat_gateway_per_az = local.vpc_common.one_nat_gateway_per_az
  single_nat_gateway     = local.vpc_common.single_nat_gateway

  flow_logs_traffic_type = local.vpc_common.flow_logs_traffic_type
  flow_logs_s3_prefix    = local.vpc_common.flow_logs_s3_prefix
  ssm_vpce_services      = local.vpc_common.ssm_vpce_services

  tags                 = local.network.primary.tags
  public_subnet_tags   = local.network.primary.public_subnet_tags
  private_subnet_tags  = local.network.primary.private_subnet_tags
  database_subnet_tags = local.network.primary.database_subnet_tags

  frontend_port = var.frontend_port
  backend_port  = var.backend_port
}

# module "network_secondary" {
#   source    = "./modules/network"
#   providers = { aws = aws.secondary }

#   name_prefix = terraform.workspace
#   role        = local.network.secondary.role

#   azs              = local.network.secondary.azs
#   vpc_cidr         = local.network.secondary.vpc_cidr
#   public_subnets   = local.network.secondary.public_subnets
#   private_subnets  = local.network.secondary.private_subnets
#   database_subnets = local.network.secondary.database_subnets

#   # comunes
#   enable_nat_gateway     = local.vpc_common.enable_nat_gateway
#   one_nat_gateway_per_az = local.vpc_common.one_nat_gateway_per_az
#   single_nat_gateway     = local.vpc_common.single_nat_gateway

#   flow_logs_traffic_type = local.vpc_common.flow_logs_traffic_type
#   flow_logs_s3_prefix    = local.vpc_common.flow_logs_s3_prefix
#   ssm_vpce_services      = local.vpc_common.ssm_vpce_services

#   tags                 = local.network.secondary.tags
#   public_subnet_tags   = local.network.secondary.public_subnet_tags
#   private_subnet_tags  = local.network.secondary.private_subnet_tags
#   database_subnet_tags = local.network.secondary.database_subnet_tags

#   frontend_port = var.frontend_port
#   backend_port  = var.backend_port
# }
