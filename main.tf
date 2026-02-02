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

module "network_secondary" {
  source    = "./modules/network"
  providers = { aws = aws.secondary }

  name_prefix = terraform.workspace
  role        = local.network.secondary.role

  azs              = local.network.secondary.azs
  vpc_cidr         = local.network.secondary.vpc_cidr
  public_subnets   = local.network.secondary.public_subnets
  private_subnets  = local.network.secondary.private_subnets
  database_subnets = local.network.secondary.database_subnets

  # comunes
  enable_nat_gateway     = local.vpc_common.enable_nat_gateway
  one_nat_gateway_per_az = local.vpc_common.one_nat_gateway_per_az
  single_nat_gateway     = local.vpc_common.single_nat_gateway

  flow_logs_traffic_type = local.vpc_common.flow_logs_traffic_type
  flow_logs_s3_prefix    = local.vpc_common.flow_logs_s3_prefix
  ssm_vpce_services      = local.vpc_common.ssm_vpce_services

  tags                 = local.network.secondary.tags
  public_subnet_tags   = local.network.secondary.public_subnet_tags
  private_subnet_tags  = local.network.secondary.private_subnet_tags
  database_subnet_tags = local.network.secondary.database_subnet_tags

  frontend_port = var.frontend_port
  backend_port  = var.backend_port
}

module "frontend_primary" {
  source    = "./modules/frontend"
  providers = { aws = aws.primary }

  name_prefix = terraform.workspace
  role        = "primary"

  vpc_id          = module.network_primary.vpc_id
  public_subnets  = module.network_primary.public_subnets
  private_subnets = module.network_primary.private_subnets

  alb_sg_id      = module.network_primary.alb_frontend_sg_id
  instance_sg_id = module.network_primary.frontend_sg_id

  min_size         = var.frontend_min_size_primary
  max_size         = var.frontend_max_size_primary
  desired_capacity = var.frontend_desired_capacity_primary

  frontend_port             = var.frontend_port
  frontend_healthcheck_path = var.frontend_healthcheck_path
  frontend_instance_type    = var.frontend_instance_type
  image_id                  = data.aws_ssm_parameter.amazon_linux_2_ami.id
  iam_instance_profile_name = aws_iam_instance_profile.ec2_frontend_profile.name

  enable_deletion_protection = var.enable_deletion_protection

  tags = merge(local.common_tags, local.primary_tags)
}

module "frontend_secondary" {
  source    = "./modules/frontend"
  providers = { aws = aws.secondary }

  name_prefix = terraform.workspace
  role        = "secondary"

  vpc_id          = module.network_secondary.vpc_id
  public_subnets  = module.network_secondary.public_subnets
  private_subnets = module.network_secondary.private_subnets

  alb_sg_id      = module.network_secondary.alb_frontend_sg_id
  instance_sg_id = module.network_secondary.frontend_sg_id

  min_size         = var.frontend_min_size_secondary
  max_size         = var.frontend_max_size_secondary
  desired_capacity = var.frontend_desired_capacity_secondary

  frontend_port             = var.frontend_port
  frontend_healthcheck_path = var.frontend_healthcheck_path
  frontend_instance_type    = var.frontend_instance_type
  image_id                  = data.aws_ssm_parameter.amazon_linux_2_ami.id
  iam_instance_profile_name = aws_iam_instance_profile.ec2_frontend_profile.name

  enable_deletion_protection = var.enable_deletion_protection

  tags = merge(local.common_tags, local.secondary_tags)
}
