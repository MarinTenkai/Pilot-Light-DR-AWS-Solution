#######################################
#### Recursos Locales del proyecto ####
#######################################

## Tags comunes del proyecto ##
locals {
  common_tags = {
    Project     = var.project_name
    Environment = terraform.workspace
    ManagedBy   = "Terraform"
  }
}

## Tags para la región Primaria ##
locals {
  primary_tags = {
    RegionRole = "Primary"
  }
}

## Tags para la región Secundaria ##
locals {
  secondary_tags = {
    RegionRole = "Secondary"
  }
}

## Network ##

#Extrae la lista de zonas disponibles en la region seleccionada
data "aws_availability_zones" "primary" {
  state = "available"
}

data "aws_availability_zones" "secondary" {
  provider = aws.secondary
  state    = "available"
}

## Selecciona las primeras N(var.az_count) AZs disponibles en la Región Primaria y Secundaria
locals {
  azs_primary   = slice(sort(data.aws_availability_zones.primary.names), 0, var.az_count)
  azs_secondary = slice(sort(data.aws_availability_zones.secondary.names), 0, var.az_count)
}

## Recursos para Networking ##

locals {
  vpc_common = {
    enable_nat_gateway     = true
    one_nat_gateway_per_az = true
    single_nat_gateway     = false
    flow_logs_traffic_type = var.flow_logs_traffic_type
    flow_logs_s3_prefix    = var.flow_logs_s3_prefix
    ssm_vpce_services      = toset(["ssm", "ec2messages", "ssmmessages"])
  }

  network = {
    primary = {
      role             = "primary"
      azs              = local.azs_primary
      vpc_cidr         = var.vpc_primary_cidr
      public_subnets   = var.public_subnets_cidrs_primary
      private_subnets  = var.private_subnets_cidrs_primary
      database_subnets = var.database_subnets_cidrs_primary

      tags                 = merge(local.common_tags, local.primary_tags)
      public_subnet_tags   = merge(local.common_tags, local.primary_tags, { Tier = "Public" })
      private_subnet_tags  = merge(local.common_tags, local.primary_tags, { Tier = "Private-app" })
      database_subnet_tags = merge(local.common_tags, local.primary_tags, { Tier = "Private-db" })
    }

    secondary = {
      role             = "secondary"
      azs              = local.azs_secondary
      vpc_cidr         = var.vpc_secondary_cidr
      public_subnets   = var.public_subnets_cidrs_secondary
      private_subnets  = var.private_subnets_cidrs_secondary
      database_subnets = var.database_subnets_cidrs_secondary

      tags                 = merge(local.common_tags, local.secondary_tags)
      public_subnet_tags   = merge(local.common_tags, local.secondary_tags, { Tier = "Public" })
      private_subnet_tags  = merge(local.common_tags, local.secondary_tags, { Tier = "Private-app" })
      database_subnet_tags = merge(local.common_tags, local.secondary_tags, { Tier = "Private-db" })
    }
  }
}

############################################
#### Llamada a módulos internos Módulos ####
############################################

#### network ####
#################

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

#### frontend ####
##################

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
  iam_instance_profile_name = aws_iam_instance_profile.ec2_frontend_profile.name

  ami_ssm_parameter_name = var.frontend_ami_ssm_parameter_name
  user_data_path         = var.frontend_user_data_path

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
  iam_instance_profile_name = aws_iam_instance_profile.ec2_frontend_profile.name

  ami_ssm_parameter_name = var.frontend_ami_ssm_parameter_name
  user_data_path         = var.frontend_user_data_path

  enable_deletion_protection = var.enable_deletion_protection

  tags = merge(local.common_tags, local.secondary_tags)
}

#### backend ####
#################

module "backend_primary" {
  source    = "./modules/backend"
  providers = { aws = aws.primary }

  name_prefix = terraform.workspace
  role        = "primary"

  vpc_id          = module.network_primary.vpc_id
  private_subnets = module.network_primary.private_subnets

  alb_sg_id      = module.network_primary.alb_backend_sg_id
  instance_sg_id = module.network_primary.backend_sg_id

  min_size         = var.backend_min_size_primary
  max_size         = var.backend_max_size_primary
  desired_capacity = var.backend_desired_capacity_primary

  backend_port              = var.backend_port
  backend_healthcheck_path  = var.backend_healthcheck_path
  backend_instance_type     = var.backend_instance_type
  iam_instance_profile_name = aws_iam_instance_profile.ec2_backend_profile.name

  ami_ssm_parameter_name = var.backend_ami_ssm_parameter_name
  user_data_path         = var.backend_user_data_path

  enable_deletion_protection = var.enable_deletion_protection

  tags = merge(local.common_tags, local.primary_tags)
}

module "backend_secondary" {
  source    = "./modules/backend"
  providers = { aws = aws.secondary }

  name_prefix = terraform.workspace
  role        = "secondary"

  vpc_id          = module.network_secondary.vpc_id
  private_subnets = module.network_secondary.private_subnets

  alb_sg_id      = module.network_secondary.alb_backend_sg_id
  instance_sg_id = module.network_secondary.backend_sg_id

  min_size         = var.backend_min_size_secondary
  max_size         = var.backend_max_size_secondary
  desired_capacity = var.backend_desired_capacity_secondary

  backend_port              = var.backend_port
  backend_healthcheck_path  = var.backend_healthcheck_path
  backend_instance_type     = var.backend_instance_type
  iam_instance_profile_name = aws_iam_instance_profile.ec2_backend_profile.name

  ami_ssm_parameter_name = var.backend_ami_ssm_parameter_name
  user_data_path         = var.backend_user_data_path

  enable_deletion_protection = var.enable_deletion_protection

  tags = merge(local.common_tags, local.secondary_tags)
}
