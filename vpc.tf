############################################
###### Recursos de la Región Primaria ######
############################################

## VPC de la región primaria
module "vpc_primary" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.6.0"

  providers = {
    aws = aws.primary
  }

  name = "${terraform.workspace}-primary"
  cidr = var.vpc_primary_cidr
  azs  = local.azs_primary

  # Subnets
  public_subnets   = var.public_subnets_cidrs_primary
  private_subnets  = var.private_subnets_cidrs_primary
  database_subnets = var.database_subnets_cidrs_primary

  enable_dns_support   = true
  enable_dns_hostnames = true

  # Internet egress
  enable_nat_gateway = true

  one_nat_gateway_per_az = true
  single_nat_gateway     = false

  # DB Subnet Group para Autora
  create_database_subnet_group = true

  # Etiquetas
  tags = merge(local.common_tags, local.primary_tags)

  # Tags por subnet
  public_subnet_tags = merge(local.common_tags, local.primary_tags, {
  Tier = "Public" })

  private_subnet_tags = merge(local.common_tags, local.primary_tags, {
  Tier = "Private-app" })

  database_subnet_tags = merge(local.common_tags, local.primary_tags, {
  Tier = "Private-db" })
}

## Recursos de S3 Bucket para VPC Flow Logs de la región primaria
module "s3_bucket_primary" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.10.0"

  providers = {
    aws = aws.primary
  }

  bucket = "${terraform.workspace}-vpc-primary-flow-logs"

  #Parámetro para entornos dev/test comentar o eliminar en producción para evitar eliminaciones accidentales
  force_destroy = true

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

#Política de bucket para permitir VPC Flow Logs escribir en el bucket de la región primaria
resource "aws_s3_bucket_policy" "flow_logs_primary" {
  bucket = module.s3_bucket_primary.s3_bucket_id

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
        Resource = "${module.s3_bucket_primary.s3_bucket_arn}/${var.flow_logs_s3_prefix}*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
          ArnLike = {
            "aws:SourceArn" = "arn:aws:ec2:${var.primary_region}:${data.aws_caller_identity.current.account_id}:vpc-flow-log/*"
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
        Resource = "${module.s3_bucket_primary.s3_bucket_arn}"
      }
    ]
  })
}

## VPC Flow Logs para registro de logs de red de la región primaria
resource "aws_flow_log" "vpc_primary" {
  vpc_id               = module.vpc_primary.vpc_id
  traffic_type         = var.flow_logs_traffic_type
  log_destination_type = "s3"
  log_destination      = "${module.s3_bucket_primary.s3_bucket_arn}/${var.flow_logs_s3_prefix}"

  max_aggregation_interval = 600

  depends_on = [aws_s3_bucket_policy.flow_logs_primary]
}

## VPC Endpoints para SSM de la región primaria
resource "aws_vpc_endpoint" "ssm_primary" {
  for_each            = local.ssm_vpce_services
  vpc_id              = module.vpc_primary.vpc_id
  service_name        = "com.amazonaws.${var.primary_region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc_primary.private_subnets
  security_group_ids  = [aws_security_group.vpce_sg_primary.id]
  private_dns_enabled = true

  tags = merge(local.common_tags, local.primary_tags)
}

##############################################
###### Recursos de la Región Secundaria ######
##############################################

