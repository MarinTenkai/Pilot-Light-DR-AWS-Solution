data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  name = "${var.name_prefix}-${var.role}" # ej: dev-primary / dev-secondary
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.6.0"

  name = local.name
  cidr = var.vpc_cidr
  azs  = var.azs

  public_subnets   = var.public_subnets
  private_subnets  = var.private_subnets
  database_subnets = var.database_subnets

  enable_dns_support   = true
  enable_dns_hostnames = true

  enable_nat_gateway     = var.enable_nat_gateway
  one_nat_gateway_per_az = var.one_nat_gateway_per_az
  single_nat_gateway     = var.single_nat_gateway

  create_database_subnet_group = true

  tags                 = var.tags
  public_subnet_tags   = var.public_subnet_tags
  private_subnet_tags  = var.private_subnet_tags
  database_subnet_tags = var.database_subnet_tags
}

module "s3_bucket_flow_logs" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.10.0"

  # S3 bucket names son globales; incluir role + region ayuda a evitar colisiones
  bucket        = "${var.name_prefix}-vpc-${var.role}-flow-logs-${data.aws_region.current.name}"
  force_destroy = var.flow_logs_force_destroy

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  control_object_ownership = true
  object_ownership         = "BucketOwnerEnforced"

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }

  tags = var.tags
}

resource "aws_s3_bucket_policy" "flow_logs" {
  bucket = module.s3_bucket_flow_logs.s3_bucket_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSVPCFlowLogsWrite"
        Effect    = "Allow"
        Principal = { Service = "vpc-flow-logs.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${module.s3_bucket_flow_logs.s3_bucket_arn}/${var.flow_logs_s3_prefix}*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
          ArnLike = {
            "aws:SourceArn" = "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:vpc-flow-log/*"
          }
        }
      },
      {
        Sid       = "AWSVPCFlowLogsAclCheck"
        Effect    = "Allow"
        Principal = { Service = "vpc-flow-logs.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = module.s3_bucket_flow_logs.s3_bucket_arn
      }
    ]
  })
}

resource "aws_flow_log" "vpc" {
  vpc_id                   = module.vpc.vpc_id
  traffic_type             = var.flow_logs_traffic_type
  log_destination_type     = "s3"
  log_destination          = "${module.s3_bucket_flow_logs.s3_bucket_arn}/${var.flow_logs_s3_prefix}"
  max_aggregation_interval = 600

  depends_on = [aws_s3_bucket_policy.flow_logs]
}

resource "aws_vpc_endpoint" "ssm" {
  for_each = var.ssm_vpce_services

  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.${each.key}"
  vpc_endpoint_type = "Interface"

  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [var.vpce_sg_id]
  private_dns_enabled = true

  tags = var.tags
}
