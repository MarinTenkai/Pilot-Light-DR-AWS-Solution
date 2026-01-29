provider "aws" {
  region = var.primary_region
  default_tags {
    tags = {
      Environment = terraform.workspace
      Owner       = "marin.tenkai"
      Project     = var.project_name
      terraform   = "true"
    }
  }
}

#Extrae la lista de zonas disponibles en la region seleccionada
data "aws_availability_zones" "available" {
  state = "available"
}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

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
  public_subnets   = var.public_subnets_cidrs_primary
  private_subnets  = var.private_subnets_cidrs_primary
  database_subnets = var.database_subnets_cidrs_primary

  enable_dns_support   = true
  enable_dns_hostnames = true

  /*Con el objetivo de reducir costes en este entorno de prueba, no se crea NAT Gateway ni se permite. 
  En un entorno real, se debería habilitar para asegurar la correcta comunicación de las subnets privadas.*/

  # Internet egress
  enable_nat_gateway = false

  #one_nat_gateway_per_az = true
  #single_nat_gateway     = false

  create_database_subnet_group = true # DB Subnet Group para Autora/RDS

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

#VPC Flow Logs resources
resource "aws_flow_log" "vpc_primary" {
  vpc_id               = module.vpc_primary.vpc_id
  traffic_type         = var.flow_logs_traffic_type
  log_destination_type = "s3"
  log_destination      = "${module.s3-bucket.s3_bucket_arn}/${var.flow_logs_s3_prefix}"

  max_aggregation_interval = 600

  depends_on = [aws_s3_bucket_policy.flow_logs]
}

module "s3-bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.10.0"

  bucket = "${var.project_name}-${terraform.workspace}-vpc-flow-logs"

  # Seguridad base
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  control_object_ownership = true
  object_ownership         = "BucketOwnerEnforced"

  # Cifrado por defecto (SSE-S3)
  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }
}

resource "aws_s3_bucket_policy" "flow_logs" {
  bucket = module.s3-bucket.s3_bucket_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSVPCFlowLogsWrite"
        Effect = "Allow"
        Principal = {
          Service = "vpc-flow-logs.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${module.s3-bucket.s3_bucket_arn}/${var.flow_logs_s3_prefix}*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
          ArnLike = {
            "aws:SourceArn" = "arn:aws:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:vpc-flow-log/*"
          }
        }
      },
      {
        Sid    = "AWSVPCFlowLogsAclCheck"
        Effect = "Allow"
        Principal = {
          Service = "vpc-flow-logs.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = "${module.s3-bucket.s3_bucket_arn}"
      }
    ]
  })
}

