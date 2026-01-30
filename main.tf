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
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}

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

#Networking - VPC primaria
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
  enable_nat_gateway = true

  one_nat_gateway_per_az = true
  single_nat_gateway     = false

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

#Compute resources

locals {
  frontend_user_data = base64encode(<<-EOF
    #!/bin/bash
    set -euxo pipefail

    sudo yum -y install git || sudo dnf -y install git || true

    sudo rm -rf /tmp/demo-terraform-101
    sudo git clone https://github.com/hashicorp/demo-terraform-101 /tmp/demo-terraform-101
    sudo sh /tmp/demo-terraform-101/assets/setup-web.sh
  EOF
  )
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"] # Amazon Linux 2023
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

## Security Group for Compute Resources

# SG del ALB (Public)
resource "aws_security_group" "alb_sg" {
  name        = "${var.project_name}-${terraform.workspace}-alb-sg"
  description = "Security Group for ALB in Primary Region"
  vpc_id      = module.vpc_primary.vpc_id

  ingress {
    description = "Allow HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "To Frontend targets"
    from_port   = var.frontend_port
    to_port     = var.frontend_port
    protocol    = "tcp"
    cidr_blocks = module.vpc_primary.private_subnets_cidr_blocks
  }
}

# SG de las instancias Frontend (Private)
resource "aws_security_group" "frontend_sg" {
  name        = "${var.project_name}-${terraform.workspace}-frontend-sg"
  description = "Security Group for Frontend instances in Primary Region"
  vpc_id      = module.vpc_primary.vpc_id

  ingress {
    description     = "HTTP from ALB"
    from_port       = var.frontend_port
    to_port         = var.frontend_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  egress {
    description = "DNS UPD to VPC resolver"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["${cidrhost(var.vpc_primary_cidr, 2)}/32"]
  }

  egress {
    description = "DNS TCP to VPC resolver"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = ["${cidrhost(var.vpc_primary_cidr, 2)}/32"]
  }

  egress {
    description = "SSM sobre HTTPS via NAT Gateway"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  dynamic "egress" {
    for_each = var.backend_sg_id == null ? [] : [var.backend_sg_id]
    content {
      description     = "Permite la comunicación desde el Frontend hacia el Backend"
      from_port       = var.backend_port
      to_port         = var.backend_port
      protocol        = "tcp"
      security_groups = [egress.value]
    }
  }
}

# ALB (Public) + Target Group + Listener

module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "10.5.0"

  name                       = "${terraform.workspace}-alb"
  load_balancer_type         = "application"
  vpc_id                     = module.vpc_primary.vpc_id
  subnets                    = module.vpc_primary.public_subnets
  security_groups            = [aws_security_group.alb_sg.id]
  enable_deletion_protection = false

  # Listener HTTP :80
  listeners = {
    http = {
      port     = 80
      protocol = "HTTP"

      forward = {
        target_group_key = "frontend"
      }
    }
  }

  # Target Groups para el ASG de Frontend

  target_groups = {
    frontend = {
      name_prefix          = "tg-"
      protocol             = "HTTP"
      port                 = var.frontend_port
      target_type          = "instance"
      deregistration_delay = 10

      create_attachment = false

      health_check = {
        enabled             = true
        path                = var.frontend_healthcheck_path
        protocol            = "HTTP"
        matcher             = "200-399"
        interval            = 30
        timeout             = 5
        healthy_threshold   = 2
        unhealthy_threshold = 2
      }
    }
  }
}

# Auto Scaling Group (Frontend) en subnets privadas

module "autoscaling" {
  source  = "terraform-aws-modules/autoscaling/aws"
  version = "9.1.0"

  name = "${var.project_name}-${terraform.workspace}-frontend-asg"

  # Subnets privadas (2 AZs)
  vpc_zone_identifier = module.vpc_primary.private_subnets

  min_size         = var.frontend_min_size
  max_size         = var.frontend_max_size
  desired_capacity = var.frontend_desired_capacity

  # Health checks desde ALB
  health_check_type         = "ELB"
  health_check_grace_period = 60

  # Adjunta el ASG al target group del ALB
  traffic_source_attachments = {
    frontend = {
      traffic_source_identifier = module.alb.target_groups["frontend"].arn
      traffic_source_type       = "elbv2"
    }
  }

  # Launch Template (Dentro del módulo)
  launch_template_name        = "${var.project_name}-${terraform.workspace}-frontend-lt"
  launch_template_description = "Frontend LT"

  image_id      = data.aws_ami.amazon_linux.id
  instance_type = var.frontend_instance_type

  #key pair por defecto
  #key_name = aws_key_pair.ssh.key_name

  #Asignamos el perfil de instancia SSM
  iam_instance_profile_name = aws_iam_instance_profile.ec2_ssm_profile.name

  # SG de las instancias
  security_groups = [aws_security_group.frontend_sg.id]

  # user data
  user_data = local.frontend_user_data

  # Etiquetas en instancias
  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${terraform.workspace}-frontend-instance"
    Tier = "Frontend"
  })
}

## Seguridad

#TLS SSH key pair
# resource "aws_key_pair" "ssh" {
#   key_name   = var.key_name
#   public_key = file(var.public_key_path)

#   tags = merge(local.common_tags, {
#     Name      = var.key_name
#     ManagedBy = "Marin.Tenkai"
#   })
# }

#SSM IAM Role y Perfil de Instancia para Instancias EC2

#Creamos la política de asunción de rol para EC2
data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

#Creamos el rol IAM para EC2
resource "aws_iam_role" "ec2_ssm_role" {
  name               = "${terraform.workspace}-ec2-ssm-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

#Adjuntamos la política gestionada de AmazonSSMManagedInstanceCore al rol IAM creado
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

#Creamos el perfil de instancia IAM para EC2
resource "aws_iam_instance_profile" "ec2_ssm_profile" {
  name = "${terraform.workspace}-ec2-ssm-profile"
  role = aws_iam_role.ec2_ssm_role.name
}
