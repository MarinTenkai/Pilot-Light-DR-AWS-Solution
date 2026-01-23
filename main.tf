provider "aws" {
  region = "eu-south-2"
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
data "aws_availability_zones" "available" {}
data "aws_region" "current" {}

#Recursos de Red, VPC, Subnets, IGW, Route Tables, NACLs, Security Groups
module "vpc_main" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.6.0"

  name = "vpc-main-${terraform.workspace}"
  cidr = "10.0.0.0/16"

  azs             = ["eu-south-2a", "eu-south-2c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]
}
