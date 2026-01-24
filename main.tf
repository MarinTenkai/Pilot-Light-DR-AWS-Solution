provider "aws" {
  region = var.primary_region
  default_tags {
    tags = {
      Environment = terraform.workspace
      Owner       = "marin.tenkai"
      Project     = "Pilot Light Disaster Recovery"
      terraform   = "true"
    }
  }
}

#Extrae la lista de zonas disponibles en la region seleccionada
data "aws_availability_zones" "available" {
  state = "available"
}
data "aws_region" "current" {}

locals {
  # Selecciona las primeras N AZss disponibles en la región primaria
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  common_tags = {
    Project     = var.project_name
    Environment = terraform.workspace
    ManagedBy   = "Terraform"
    RegionRole  = "Primary"
  }
}

#Recursos de Red, VPC, Subnets, IGW, Route Tables, NACLs, Security Groups
module "vpc_primary" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.6.0"

  name = "${var.project_name}-${terraform.workspace}-primary"
  cidr = var.vpc_primary_cidr
  azs  = local.azs

  # Subnets
  public_subnets   = var.public_subnets_cidrs
  private_subnets  = var.private_subnets_cidrs
  database_subnets = var.database_subnets_cidrs

  enable_dns_support   = true
  enable_dns_hostnames = true

  #Por motivos de coste en este entorno de ejemplo, no se crea NAT Gateway ni se permite. En un entorno real, se debería habilitar.
  # Internet egress
  enable_nat_gateway = false

  #one_nat_gateway_per_az = true
  #single_nat_gateway     = false

  # DB Subnet Group para Autora/RDS
  create_database_subnet_group = true

  # Etiquetas
  tags = local.common_tags

  # Tags por subnet
  public_subnet_tags = merge(local.common_tags, {
  Tier = "Public" })

  private_subnet_tags = merge(local.common_tags, {
  Tier = "Private-app" })

  database_subnet_tags = merge(local.common_tags, {
  Tier = "Private-db" })
}
