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

#### Recursos comunes para la región primaria y secundaria ####

## Regiones y AZs

#Extrae la lista de zonas disponibles en la region seleccionada
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}
# Selecciona las primeras N AZss disponibles en la región primaria
locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  common_tags = {
    Project     = var.project_name
    Environment = terraform.workspace
    ManagedBy   = "Terraform"
    RegionRole  = "Primary"
  }
}

## Recursos de S3 Bucket para VPC Flow Logs
module "s3-bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.10.0"

  bucket = "${terraform.workspace}-vpc-flow-logs"

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

#Política de bucket para permitir VPC Flow Logs escribir en el bucket
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

## Recursos de computación comunes para las capas frontend y backend

# AMI para instancias EC2 (Amazon Linux 2)
data "aws_ssm_parameter" "amazon_linux_2_ami" {
  name = "/aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-gp2"
}

# User Data para instancias Frontend
locals {
  frontend_user_data = base64encode(<<-EOF
    #!/bin/bash
    set -euxo pipefail

    mkdir -p /var/www/html
    cat > /var/www/html/index.html <<'HTML'
    <h1>OK - Instancia responde</h1>
    <p>Esta es una página de prueba servida desde la instancia Frontend.</p>
    HTML

    nohup python3 -m http.server ${var.frontend_port} --directory /var/www/html >/var/log/frontend-server.log 2>&1 &
  EOF
  )
}

# User Data para instancias Backend
locals {

  backend_user_data = base64encode(<<-EOF
    #!/bin/bash
    set -euxo pipefail

    mkdir -p /var/www/backend

    cat > /var/www/backend/index.html <<'HTML'
    <h1>OK - Backend Instance</h1>
    <p>Esta es una página de prueba servida desde la instancia Backend (Application Server).</p>
    HTML

    nohup python3 -m http.server ${var.backend_port} --directory /var/www/backend >/var/log/backend-server.log 2>&1 &
  EOF
  )
}

## SSM - IAM Role y Perfil de Instancia para Instancias EC2

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

# recursos de VPC Endpoints para SSM
locals {
  ssm_vpce_services = toset(["ssm", "ec2messages", "ssmmessages"])
}

#### Recursos para la región primaria ####

## VPC primaria

module "vpc_primary" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.6.0"

  name = "${terraform.workspace}-primary"
  cidr = var.vpc_primary_cidr
  azs  = local.azs

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
  tags = local.common_tags

  # Tags por subnet
  public_subnet_tags = merge(local.common_tags, {
  Tier = "Public" })

  private_subnet_tags = merge(local.common_tags, {
  Tier = "Private-app" })

  database_subnet_tags = merge(local.common_tags, {
  Tier = "Private-db" })
}

## VPC primaria Flow Logs para registro de logs de red
resource "aws_flow_log" "vpc_primary" {
  vpc_id               = module.vpc_primary.vpc_id
  traffic_type         = var.flow_logs_traffic_type
  log_destination_type = "s3"
  log_destination      = "${module.s3-bucket.s3_bucket_arn}/${var.flow_logs_s3_prefix}"

  max_aggregation_interval = 600

  depends_on = [aws_s3_bucket_policy.flow_logs]
}

## VPC Endpoints para SSM
resource "aws_vpc_endpoint" "ssm" {
  for_each            = local.ssm_vpce_services
  vpc_id              = module.vpc_primary.vpc_id
  service_name        = "com.amazonaws.${var.primary_region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc_primary.private_subnets
  security_group_ids  = [aws_security_group.vpce_sg.id]
  private_dns_enabled = true

  tags = local.common_tags
}

#### Grupos de seguridad para los recursos de la región primaria ####

## Grupos de seguridad de la capa Frontend de la región primaria

# SG para VPC Endpoints SSM
resource "aws_security_group" "vpce_sg" {
  name        = "${terraform.workspace}-vpce-sg"
  description = "SG para VPC Endpoints SSM"
  vpc_id      = module.vpc_primary.vpc_id

  ingress {
    description     = "HTTPS desde instancias frontend hacia VPC Endpoint"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.frontend_sg.id]
  }

  #Esto es realmente necesario? revisar.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.common_tags
}

# SG del ALB (Public) para la capa Frontend de la región primaria
resource "aws_security_group" "alb_sg" {
  name        = "${terraform.workspace}-alb-sg"
  description = "Security Group for ALB in Primary Region"
  vpc_id      = module.vpc_primary.vpc_id

  #puertos hardcodeados y además no entiendo porque permito http pero no https.
  ingress {
    description = "Permitir el tráfico entrante desde internet hasta el ALB público"
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
    cidr_blocks = module.vpc_primary.private_subnets_cidr_blocks #Me gustaría cambiar esto por un security_groups
  }
}

# SG de las instancias Frontend (Private) de la región primaria
resource "aws_security_group" "frontend_sg" {
  name        = "${terraform.workspace}-frontend-sg"
  description = "Security Group for Frontend instances in Primary Region"
  vpc_id      = module.vpc_primary.vpc_id

  ingress {
    description     = "Permitir tráfico desde el ALB público hacia las instancias en el frontend"
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

  #No entiendo este egress REVISAR
  egress {
    description = "SSM sobre HTTP via NAT Gateway"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

## Grupos de seguridad de la capa Backend de la región primaria

resource "aws_security_group" "backend_sg" {
  name        = "${terraform.workspace}-backend-sg"
  description = "Security Group para las instancias Backend en la región primaria"
  vpc_id      = module.vpc_primary.vpc_id

  egress {
    description = "DNS UDP para VPC resolver"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["${cidrhost(var.vpc_primary_cidr, 2)}/32"]
  }

  egress {
    description = "DNS TCP para VPC resolver"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = ["${cidrhost(var.vpc_primary_cidr, 2)}/32"]
  }

  #No entiendo este egress. por qué el backend debe salir a internet?
  egress {
    description = "HTTPS egress"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    name = "${terraform.workspace}-backend-sg"
    Tier = "Backend"
  })
}

resource "aws_security_group" "backend_alb_sg" {
  name        = "${terraform.workspace}-backend-alb-sg"
  description = "Grupo de Seguridad para el ALB del Backend en la región primaria"
  vpc_id      = module.vpc_primary.vpc_id

  ingress {
    description     = "Permitir trafico desde las instancias frontend hacia el ALB interno"
    from_port       = var.backend_port
    to_port         = var.backend_port
    protocol        = "tcp"
    security_groups = [aws_security_group.frontend_sg.id]
  }

  egress {
    description     = "Egress al Backend targets"
    from_port       = var.backend_port
    to_port         = var.backend_port
    protocol        = "tcp"
    security_groups = [aws_security_group.backend_sg.id]
  }

  tags = merge(local.common_tags, {
    name = "${terraform.workspace}-backend-alb-sg"
    Tier = "Backend"
  })
}


##

# Frontend -> Backend ALB (egress)
resource "aws_security_group_rule" "frontend_egress_to_backend_alb" {
  description              = "Permite al frontend llamar al backend a traves del ALB interno"
  type                     = "egress"
  security_group_id        = aws_security_group.frontend_sg.id
  from_port                = var.backend_port
  to_port                  = var.backend_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.backend_alb_sg.id
}

# Backend ALB -> Backend instances (ingress en backend_sg)
resource "aws_security_group_rule" "backend_ingress_from_backend_alb" {
  description              = "Permite el trafico desde el ALB interno hacia las instancias en el backend"
  type                     = "ingress"
  security_group_id        = aws_security_group.backend_sg.id
  from_port                = var.backend_port
  to_port                  = var.backend_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.backend_alb_sg.id
}

#### Recursos de la capa Frontend de la región primaria ####

## ALB (Public) + Target Group + Listener, de la región primaria

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

## Auto Scaling Group para instancias Frontend

module "autoscaling" {
  source  = "terraform-aws-modules/autoscaling/aws"
  version = "9.1.0"

  name = "${terraform.workspace}-frontend-asg"

  # Subnets privadas (2 AZs)
  vpc_zone_identifier = module.vpc_primary.private_subnets

  min_size         = var.frontend_min_size
  max_size         = var.frontend_max_size
  desired_capacity = var.frontend_desired_capacity

  # Health checks desde ALB
  health_check_type         = "ELB"
  health_check_grace_period = 180

  # Adjunta el ASG al target group del ALB
  traffic_source_attachments = {
    frontend = {
      traffic_source_identifier = module.alb.target_groups["frontend"].arn
      traffic_source_type       = "elbv2"
    }
  }

  # Launch Template para las instancias Frontend
  launch_template_name        = "${terraform.workspace}-frontend-lt"
  launch_template_description = "Frontend LT"

  image_id      = data.aws_ssm_parameter.amazon_linux_2_ami.value
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
    Name = "${terraform.workspace}-frontend-instance"
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

#### Recursos de la capa backend de la región primaria ####

