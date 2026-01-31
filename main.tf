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

### Recursos de RDS Database ###

## Grupos de seguridad, ajustes de red y reglas para RDS PostgresSQL

# Subnet Group para RDS usando las subnets "database" del módulo VPC

resource "aws_db_subnet_group" "postgresql" {
  name       = "${terraform.workspace}j-postgresql-subnet-group"
  subnet_ids = module.vpc_primary.database_subnets

  tags = merge(local.common_tags, {
    name = "${terraform.workspace}-postgresql-subnet-group"
    tier = "Database"
  })
}

# Grupo de seguridad para RDS
resource "aws_security_group" "rds_sg" {
  name        = "${terraform.workspace}-rds-sg"
  description = "SG para rds: solo accesible desde backend"
  vpc_id      = module.vpc_primary.vpc_id

  tags = merge(local.common_tags, {
    name = "${terraform.workspace}-rds-sg"
    tier = "Database"
  })
}

# Regla Backend -> rds (egress necesario porque backend_sg es restrictivo)
resource "aws_security_group_rule" "backend_egress_to_rds" {
  type                     = "egress"
  security_group_id        = aws_security_group.backend_sg.id
  description              = "Backend hacia rds"
  from_port                = var.db_port
  to_port                  = var.db_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.rds_sg.id
}

# Regla rds <- Backend (ingress)
resource "aws_security_group_rule" "rds_ingress_from_backend" {
  type                     = "ingress"
  security_group_id        = aws_security_group.rds_sg.id
  description              = "Backend hacia rds"
  from_port                = var.db_port
  to_port                  = var.db_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.backend_sg.id
}

## Recursos para RDS PostgresSQL Multi-AZ

resource "aws_db_instance" "postgresql" {
  identifier = "${terraform.workspace}-postgresql"

  engine         = "postgres"
  instance_class = var.postgresql_instance_class

  db_name                     = var.postgresql_db_name
  username                    = var.postgresql_master_username
  manage_master_user_password = true
  port                        = var.db_port

  #Red/VPC
  db_subnet_group_name   = aws_db_subnet_group.postgresql.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  publicly_accessible    = false

  # Multi-AZ:
  multi_az = true
  #availability_zone = local.azs[0] # "preferencia" inicial (tras failover puede cambiar)

  # Storage
  allocated_storage     = var.postgresql_allocated_storage
  max_allocated_storage = var.postgresql_max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  # Operación (modo lab)
  apply_immediately       = true
  skip_final_snapshot     = true
  deletion_protection     = false
  backup_retention_period = 1

  tags = merge(local.common_tags, {
    name = "${terraform.workspace}-postgresql"
    tier = "Database"
  })
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
    <h1>OK - Frontend Instance</h1>
    <p>Esta es una pagina de prueba servida desde la instancia Frontend.</p>
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

    # Dependencias mínimas para el check
    yum -y install jq awscli postgresql || true

    # Variables DB (no sensibles)
    export DB_HOST="${aws_db_instance.postgresql.address}"
    export DB_PORT="${var.db_port}"
    export DB_NAME="${var.postgresql_db_name}"
    export DB_SECRET_ARN='${aws_db_instance.postgresql.master_user_secret[0].secret_arn}'

    mkdir -p /var/www/backend

    cat > /var/www/backend/index.html <<'HTML'
    <h1>OK - Backend Instance</h1>
    <p>Backend arriba.</p>
    <p>DB check: <a href="/dbcheck.html">/dbcheck.html</a></p>
    HTML

    cat > /usr/local/bin/dbcheck.sh <<'SH'
    #!/bin/bash
    set -euo pipefail

    LOG="/var/log/dbcheck.log"
    OUT="/var/www/backend/dbcheck.html"

    echo "==== $(date -Is) dbcheck start ====" >> "$LOG"
    echo "DB_HOST=$DB_HOST DB_PORT=$DB_PORT DB_NAME=$DB_NAME" >> "$LOG"

    # 1) DNS
    if getent hosts "$DB_HOST" >/dev/null 2>&1; then
      DNS_OK="yes"
    else
      DNS_OK="no"
    fi

    # 2) Recupera credenciales desde Secrets Manager (password gestionada por RDS)
    SECRET_JSON="$(aws secretsmanager get-secret-value --secret-id "$DB_SECRET_ARN" --query SecretString --output text 2>>"$LOG")"
    DB_USER="$(echo "$SECRET_JSON" | jq -r .username)"
    DB_PASS="$(echo "$SECRET_JSON" | jq -r .password)"

    # 3) Query real
    set +e
    RESULT="$(PGPASSWORD="$DB_PASS" psql \
      "host=$DB_HOST port=$DB_PORT dbname=$DB_NAME user=$DB_USER sslmode=require connect_timeout=5" \
      -tAc "select now() as db_time, inet_server_addr() as server_ip, inet_server_port() as server_port, pg_is_in_recovery() as in_recovery;" 2>&1)"
    RC=$?
    set -e

    if [ $RC -eq 0 ]; then
      echo "dbcheck OK: $RESULT" >> "$LOG"
      cat > "$OUT" <<HTML
    <h1>DB CHECK: OK</h1>
    <p><b>time:</b> $(date -Is)</p>
    <p><b>dns_ok:</b> $DNS_OK</p>
    <p><b>result:</b> $RESULT</p>
HTML
      exit 0
    else
      echo "dbcheck FAIL (rc=$RC): $RESULT" >> "$LOG"
      cat > "$OUT" <<HTML
    <h1>DB CHECK: FAIL</h1>
    <p><b>time:</b> $(date -Is)</p>
    <p><b>dns_ok:</b> $DNS_OK</p>
    <p><b>error (last output):</b></p>
    <pre>$(echo "$RESULT" | tail -n 30)</pre>
HTML
      exit 1
    fi
    SH

    chmod +x /usr/local/bin/dbcheck.sh

    # Ejecuta el check con reintentos (sin tumbar el boot si falla)
    ( for i in {1..12}; do /usr/local/bin/dbcheck.sh && break || true; sleep 10; done ) || true

    # Servidor HTTP actual del backend
    nohup python3 -m http.server ${var.backend_port} --directory /var/www/backend >/var/log/backend-server.log 2>&1 &
  EOF
  )
}

### SSM - IAM Role y Perfil de Instancia para Instancias EC2 Frontend y Backend ###

# recursos de VPC Endpoints para SSM
locals {
  ssm_vpce_services = toset(["ssm", "ec2messages", "ssmmessages"])
}

## IAM Role y Perfil de Instancias para Frontend

#Creamos la política de asunción de rol para EC2 FRONTEND
data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

#Creamos el rol IAM para EC2 FRONTEND
resource "aws_iam_role" "ec2_frontend_role" {
  name               = "${terraform.workspace}-ec2-frontend-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

#Adjuntamos la política gestionada de AmazonSSMManagedInstanceCore al rol IAM EC2 FRONTEND
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_frontend_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

#Creamos el perfil de instancia IAM para EC2 FRONTEND
resource "aws_iam_instance_profile" "ec2_frontend_profile" {
  name = "${terraform.workspace}-ec2-frontend-profile"
  role = aws_iam_role.ec2_frontend_role.name
}

## IAM Role y Perfil de Instancias para Backend

#Creamos la política de asunción de rol para EC2 BACKEND
data "aws_iam_policy_document" "backend_read_db_secret" {
  statement {
    sid    = "ReadRdsManagedSecret"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret"
    ]
    resources = [
      aws_db_instance.postgresql.master_user_secret[0].secret_arn
    ]
  }
}

#Creamos el rol IAM para EC2 BACKEND
resource "aws_iam_role" "ec2_backend_role" {
  name               = "${terraform.workspace}-ec2-backend-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

#Adjuntamos la política gestionada de AmazonSSMManagedInstanceCore al rol IAM EC2 BACKEND
resource "aws_iam_role_policy_attachment" "backend_ssm_core" {
  role       = aws_iam_role.ec2_backend_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

#Creamos el perfil de instancia IAM para EC2 BACKEND
resource "aws_iam_instance_profile" "ec2_backend_profile" {
  name = "${terraform.workspace}-ec2-backend-profile"
  role = aws_iam_role.ec2_backend_role.name
}

resource "aws_iam_policy" "backend_read_db_secret" {
  name   = "${terraform.workspace}-backend-read-db-secret"
  policy = data.aws_iam_policy_document.backend_read_db_secret.json
}

resource "aws_iam_role_policy_attachment" "backend_read_db_secret_attach" {
  role       = aws_iam_role.ec2_backend_role.name
  policy_arn = aws_iam_policy.backend_read_db_secret.arn
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

#### Grupos de seguridad y reglas para los recursos de la región primaria ####


## Recursos locales
locals {
  vpc_resolver_cidr = "${cidrhost(var.vpc_primary_cidr, 2)}/32"

  app_instance_sg = {
    frontend = aws_security_group.frontend_sg.id
    backend  = aws_security_group.backend_sg.id
  }
}

## Grupos de seguridad para los recursos de la región primaria

# SG del ALB público (Internet -> ALB)
resource "aws_security_group" "alb_sg" {
  name        = "${terraform.workspace}-alb-sg"
  description = "SG para ALB publico (entrada desde internet)"
  vpc_id      = module.vpc_primary.vpc_id

  tags = merge(local.common_tags, {
    name = "${terraform.workspace}alb-sg"
    Tier = "Public"
  })
}

# SG instancias Frontend (ALB publico -> Frontend)
resource "aws_security_group" "frontend_sg" {
  name        = "${terraform.workspace}-frontend-sg"
  description = "SG para instancias Frontend (solo desde ALB publico)"
  vpc_id      = module.vpc_primary.vpc_id

  tags = merge(local.common_tags, {
    name = "${terraform.workspace}-frontend-sg"
    Tier = "Frontend"
  })
}

# SG del ALB interno (Frontend -> ALB interno)
resource "aws_security_group" "backend_alb_sg" {
  name        = "${terraform.workspace}-backend-alb-sg"
  description = "SG para ALB interno del Backend (solo desde Frontend)"
  vpc_id      = module.vpc_primary.vpc_id

  tags = merge(local.common_tags, {
    name = "${terraform.workspace}-backend-alb-sg"
    tier = "Backend"
  })
}

# SG instancias Backend (ALB interno -> Backend)
resource "aws_security_group" "backend_sg" {
  name        = "${terraform.workspace}-backend-sg"
  description = "SG para instancias Backend (solo desde ALB interno)"
  vpc_id      = module.vpc_primary.vpc_id

  tags = merge(local.common_tags, {
    name = "${terraform.workspace}-backend-sg"
    tier = "Backend"
  })
}

# SG para VPC Endpoints de SSM (Frontend/Backend -> VPCE)
resource "aws_security_group" "vpce_sg" {
  name        = "${terraform.workspace}-vpce-sg"
  description = "SG para interface Endpoints de SSM (443 desde Frontend/Backend)"
  vpc_id      = module.vpc_primary.vpc_id

  tags = merge(local.common_tags, {
    name = "${terraform.workspace}-vpce-sg"
    tier = "Private"
  })
}

## Reglas para security groups

# Reglas Internet <-> ALB publico
resource "aws_security_group_rule" "alb_ingress_http" {
  type              = "ingress"
  security_group_id = aws_security_group.alb_sg.id
  description       = "Internet hacia ALB publico (HTTP)"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "alb_ingress_https" {
  type              = "ingress"
  security_group_id = aws_security_group.alb_sg.id
  description       = "Internet hacia ALB publico (HTTPS)"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
}

# Reglas ALB publico <-> Frontend
resource "aws_security_group_rule" "alb_egress_to_frontend" {
  type                     = "egress"
  security_group_id        = aws_security_group.alb_sg.id
  description              = "ALB publico hacia Frontend"
  from_port                = var.frontend_port
  to_port                  = var.frontend_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.frontend_sg.id
}

resource "aws_security_group_rule" "frontend_ingress_from_alb" {
  type                     = "ingress"
  security_group_id        = aws_security_group.frontend_sg.id
  description              = "ALB publico hacia Frontend"
  from_port                = var.frontend_port
  to_port                  = var.frontend_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb_sg.id
}

# Reglas Frontend <-> ALB interno (Backend ALB)
resource "aws_security_group_rule" "frontend_egress_to_backend_alb" {
  type                     = "egress"
  security_group_id        = aws_security_group.frontend_sg.id
  description              = "Frontend hacia ALB interno (Backend)"
  from_port                = var.backend_port
  to_port                  = var.backend_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.backend_alb_sg.id
}

resource "aws_security_group_rule" "backend_alb_ingress_from_frontend" {
  type                     = "ingress"
  security_group_id        = aws_security_group.backend_alb_sg.id
  description              = "Frontend hacia ALB interno"
  from_port                = var.backend_port
  to_port                  = var.backend_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.frontend_sg.id
}

# Reglas ALB interno <-> instancias
resource "aws_security_group_rule" "backend_alb_egress_to_backend" {
  type                     = "egress"
  security_group_id        = aws_security_group.backend_alb_sg.id
  description              = "ALB interno hacia Backend"
  from_port                = var.backend_port
  to_port                  = var.backend_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.backend_sg.id
}

resource "aws_security_group_rule" "backend_ingress_from_backend_alb" {
  type                     = "ingress"
  security_group_id        = aws_security_group.backend_sg.id
  description              = "ALB interno hacia Backend"
  from_port                = var.backend_port
  to_port                  = var.backend_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.backend_alb_sg.id
}

# Reglas SSM via interfaces Endpoints (443)
# Egress desde instancias -> VPCE (SSM)
resource "aws_security_group_rule" "app_egress_to_vpce_443" {
  for_each = local.app_instance_sg

  type                     = "egress"
  security_group_id        = each.value
  description              = "Instancias ${each.key} hacia VPCE SSM (443)"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.vpce_sg.id
}

# Ingress en VPCE desde instancias
resource "aws_security_group_rule" "vpce_ingress_from_apps_443" {
  for_each = local.app_instance_sg

  type                     = "ingress"
  security_group_id        = aws_security_group.vpce_sg.id
  description              = "Instancias ${each.key} (443) hacia VPCE SSM"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = each.value
}

# Reglas DNS (53) desde instancias
resource "aws_security_group_rule" "app_egress_dns_upd" {
  for_each = local.app_instance_sg

  type              = "egress"
  security_group_id = each.value
  description       = "Instancias ${each.key} hacia DNS UDP (VPC resolver)"
  from_port         = 53
  to_port           = 53
  protocol          = "udp"
  cidr_blocks       = [local.vpc_resolver_cidr]
}

resource "aws_security_group_rule" "app_egress_dns_tcp" {
  for_each = local.app_instance_sg

  type              = "egress"
  security_group_id = each.value
  description       = "Instancias ${each.key} hacia DNS TCP (VPC resolver)"
  from_port         = 53
  to_port           = 53
  protocol          = "tcp"
  cidr_blocks       = [local.vpc_resolver_cidr]
}

# Reglas Egress a Internet (via NAT) para dependencias/repos externos
resource "aws_security_group_rule" "app_egress_https_internet" {
  for_each = local.app_instance_sg

  type              = "egress"
  security_group_id = each.value
  description       = "Instancias ${each.key} hacia Internet HTTPS (via NAT)"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
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
  iam_instance_profile_name = aws_iam_instance_profile.ec2_frontend_profile.name

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

## ALB interno para Backend

module "backend_alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "10.5.0"

  name               = "${terraform.workspace}-backend-alb"
  load_balancer_type = "application"
  internal           = true

  vpc_id          = module.vpc_primary.vpc_id
  subnets         = module.vpc_primary.private_subnets
  security_groups = [aws_security_group.backend_alb_sg.id]

  enable_deletion_protection = false

  listeners = {
    http_backend = {
      port     = var.backend_port
      protocol = "HTTP"

      forward = {
        target_group_key = "backend"
      }
    }
  }

  target_groups = {
    backend = {
      name_prefix          = "tg-"
      protocol             = "HTTP"
      port                 = var.backend_port
      target_type          = "instance"
      deregistration_delay = 10

      create_attachment = false

      health_check = {
        enabled             = true
        path                = var.backend_healthcheck_path
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

## Backend ASG (Application Servers)
module "autoscaling_backend" {
  source  = "terraform-aws-modules/autoscaling/aws"
  version = "9.1.0"

  name = "${terraform.workspace}-backend-asg"

  vpc_zone_identifier = module.vpc_primary.private_subnets

  min_size         = var.backend_min_size
  max_size         = var.backend_max_size
  desired_capacity = var.backend_desired_capacity

  health_check_type         = "ELB"
  health_check_grace_period = 180

  traffic_source_attachments = {
    backend = {
      traffic_source_identifier = module.backend_alb.target_groups["backend"].arn
      traffic_source_type       = "elbv2"
    }
  }

  launch_template_name        = "${terraform.workspace}-backend-lt"
  launch_template_description = "Backend LT"

  image_id      = data.aws_ssm_parameter.amazon_linux_2_ami.value
  instance_type = var.backend_instance_type

  iam_instance_profile_name = aws_iam_instance_profile.ec2_backend_profile.name

  security_groups = [aws_security_group.backend_sg.id]
  user_data       = local.backend_user_data

  tags = merge(local.common_tags, {
    name = "${terraform.workspace}-backend-instance"
    tier = "Backend"
  })
}
