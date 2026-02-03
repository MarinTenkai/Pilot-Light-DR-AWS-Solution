locals {
  # Resolver CIDR (x.x.x.2/32)
  vpc_resolver_cidr = "${cidrhost(module.vpc.vpc_cidr_block, 2)}/32"
}

# Mapa de SGs de instancias (antes era local.app_instance_sg_primary en root)
locals {
  app_instance_sg = {
    frontend = aws_security_group.frontend_sg.id
    backend  = aws_security_group.backend_sg.id
  }
}

###################################
#### Security Groups (Network) ####
###################################

# SG del ALB público (Internet -> ALB)
resource "aws_security_group" "alb_frontend_sg" {
  name        = "${var.name_prefix}-alb-sg"
  description = "SG para ALB publico (entrada desde internet)"
  vpc_id      = module.vpc.vpc_id

  tags = merge(var.tags, {
    name = "${var.name_prefix}alb-sg"
    Tier = "Public"
  })
}

# SG instancias Frontend (ALB publico -> Frontend)
resource "aws_security_group" "frontend_sg" {
  name        = "${var.name_prefix}-frontend-sg"
  description = "SG para instancias Frontend (solo desde ALB publico)"
  vpc_id      = module.vpc.vpc_id

  tags = merge(var.tags, {
    name = "${var.name_prefix}-frontend-sg"
    Tier = "Frontend"
  })
}

# SG del ALB interno (Frontend -> ALB interno)
resource "aws_security_group" "alb_backend_sg" {
  name        = "${var.name_prefix}-backend-alb-sg"
  description = "SG para ALB interno del Backend (solo desde Frontend)"
  vpc_id      = module.vpc.vpc_id

  tags = merge(var.tags, {
    name = "${var.name_prefix}-backend-alb-sg"
    tier = "Backend"
  })
}

# SG instancias Backend (ALB interno -> Backend)
resource "aws_security_group" "backend_sg" {
  name        = "${var.name_prefix}-backend-sg"
  description = "SG para instancias Backend (solo desde ALB interno)"
  vpc_id      = module.vpc.vpc_id

  tags = merge(var.tags, {
    name = "${var.name_prefix}-backend-sg"
    tier = "Backend"
  })
}

# SG para RDS PostgreSQL
resource "aws_security_group" "db_sg" {
  name        = "${var.name_prefix}-db-sg"
  description = "SG para RDS PostgreSQL (solo desde Backend)"
  vpc_id      = module.vpc.vpc_id

  tags = merge(var.tags, {
    name = "${var.name_prefix}-db-sg"
    tier = "Database"
  })
}

# SG para VPC Endpoints de SSM (Frontend/Backend -> VPCE)
resource "aws_security_group" "vpce_sg" {
  name        = "${var.name_prefix}-vpce-sg"
  description = "SG para interface Endpoints de SSM (443 desde Frontend/Backend)"
  vpc_id      = module.vpc.vpc_id

  tags = merge(var.tags, {
    name = "${var.name_prefix}-vpce-sg"
    tier = "Private"
  })
}

##############################
#### Security Group Rules ####
##############################

# Internet <-> ALB publico
resource "aws_security_group_rule" "alb_ingress_http" {
  type              = "ingress"
  security_group_id = aws_security_group.alb_frontend_sg.id
  description       = "Internet hacia ALB publico (HTTP)"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "alb_ingress_https" {
  type              = "ingress"
  security_group_id = aws_security_group.alb_frontend_sg.id
  description       = "Internet hacia ALB publico (HTTPS)"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
}

# ALB publico <-> Frontend
resource "aws_security_group_rule" "alb_egress_to_frontend" {
  type                     = "egress"
  security_group_id        = aws_security_group.alb_frontend_sg.id
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
  source_security_group_id = aws_security_group.alb_frontend_sg.id
}

# Frontend <-> ALB interno
resource "aws_security_group_rule" "frontend_egress_to_alb_backend" {
  type                     = "egress"
  security_group_id        = aws_security_group.frontend_sg.id
  description              = "Frontend hacia ALB interno (Backend)"
  from_port                = var.backend_port
  to_port                  = var.backend_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb_backend_sg.id
}

resource "aws_security_group_rule" "alb_backend_ingress_from_frontend" {
  type                     = "ingress"
  security_group_id        = aws_security_group.alb_backend_sg.id
  description              = "Frontend hacia ALB interno"
  from_port                = var.backend_port
  to_port                  = var.backend_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.frontend_sg.id
}

# ALB interno <-> Backend
resource "aws_security_group_rule" "alb_backend_egress_to_backend" {
  type                     = "egress"
  security_group_id        = aws_security_group.alb_backend_sg.id
  description              = "ALB interno hacia Backend"
  from_port                = var.backend_port
  to_port                  = var.backend_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.backend_sg.id
}

resource "aws_security_group_rule" "backend_ingress_from_alb_backend" {
  type                     = "ingress"
  security_group_id        = aws_security_group.backend_sg.id
  description              = "ALB interno hacia Backend"
  from_port                = var.backend_port
  to_port                  = var.backend_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb_backend_sg.id
}

# Backend -> DB (5432) (egress explícito; aunque exista egress por defecto)
resource "aws_security_group_rule" "backend_egress_to_db" {
  type                     = "egress"
  security_group_id        = aws_security_group.backend_sg.id
  description              = "Backend hacia RDS PostgreSQL (5432)"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.db_sg.id
}

# DB <- Backend (5432)
resource "aws_security_group_rule" "db_ingress_from_backend" {
  type                     = "ingress"
  security_group_id        = aws_security_group.db_sg.id
  description              = "RDS PostgreSQL desde Backend (5432)"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.backend_sg.id
}

# SSM via VPCE (443)
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

# DNS (53) desde instancias al VPC resolver
resource "aws_security_group_rule" "app_egress_dns_udp" {
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

# HTTPS a Internet (via NAT)
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
