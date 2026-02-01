#### Grupos de seguridad y reglas para los recursos de la región primaria ####

# SG del ALB público (Internet -> ALB)
resource "aws_security_group" "alb_frontend_sg_primary" {
  name        = "${terraform.workspace}-alb-sg"
  description = "SG para ALB publico (entrada desde internet)"
  vpc_id      = module.vpc_primary.vpc_id

  tags = merge(local.common_tags, local.primary_tags, {
    name = "${terraform.workspace}alb-sg"
    Tier = "Public"
  })
}

# SG instancias Frontend (ALB publico -> Frontend)
resource "aws_security_group" "frontend_sg_primary" {
  name        = "${terraform.workspace}-frontend-sg"
  description = "SG para instancias Frontend (solo desde ALB publico)"
  vpc_id      = module.vpc_primary.vpc_id

  tags = merge(local.common_tags, local.primary_tags, {
    name = "${terraform.workspace}-frontend-sg"
    Tier = "Frontend"
  })
}

# SG del ALB interno (Frontend -> ALB interno)
resource "aws_security_group" "alb_backend_sg_primary" {
  name        = "${terraform.workspace}-backend-alb-sg"
  description = "SG para ALB interno del Backend (solo desde Frontend)"
  vpc_id      = module.vpc_primary.vpc_id

  tags = merge(local.common_tags, local.primary_tags, {
    name = "${terraform.workspace}-backend-alb-sg"
    tier = "Backend"
  })
}

# SG instancias Backend (ALB interno -> Backend)
resource "aws_security_group" "backend_sg_primary" {
  name        = "${terraform.workspace}-backend-sg"
  description = "SG para instancias Backend (solo desde ALB interno)"
  vpc_id      = module.vpc_primary.vpc_id

  tags = merge(local.common_tags, local.primary_tags, {
    name = "${terraform.workspace}-backend-sg"
    tier = "Backend"
  })
}

# SG para VPC Endpoints de SSM (Frontend/Backend -> VPCE)
resource "aws_security_group" "vpce_sg_primary" {
  name        = "${terraform.workspace}-vpce-sg"
  description = "SG para interface Endpoints de SSM (443 desde Frontend/Backend)"
  vpc_id      = module.vpc_primary.vpc_id

  tags = merge(local.common_tags, local.primary_tags, {
    name = "${terraform.workspace}-vpce-sg"
    tier = "Private"
  })
}

## Reglas para security groups

# Reglas Internet <-> ALB publico
resource "aws_security_group_rule" "alb_ingress_http_primary" {
  type              = "ingress"
  security_group_id = aws_security_group.alb_frontend_sg_primary.id
  description       = "Internet hacia ALB publico (HTTP)"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "alb_ingress_https_primary" {
  type              = "ingress"
  security_group_id = aws_security_group.alb_frontend_sg_primary.id
  description       = "Internet hacia ALB publico (HTTPS)"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
}

# Reglas ALB publico <-> Frontend
resource "aws_security_group_rule" "alb_egress_to_frontend_primary" {
  type                     = "egress"
  security_group_id        = aws_security_group.alb_frontend_sg_primary.id
  description              = "ALB publico hacia Frontend"
  from_port                = var.frontend_port
  to_port                  = var.frontend_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.frontend_sg_primary.id
}

resource "aws_security_group_rule" "frontend_ingress_from_alb" {
  type                     = "ingress"
  security_group_id        = aws_security_group.frontend_sg_primary.id
  description              = "ALB publico hacia Frontend"
  from_port                = var.frontend_port
  to_port                  = var.frontend_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb_frontend_sg_primary.id
}

# Reglas Frontend <-> ALB interno (Backend ALB)
resource "aws_security_group_rule" "frontend_egress_to_alb_backend_primary" {
  type                     = "egress"
  security_group_id        = aws_security_group.frontend_sg_primary.id
  description              = "Frontend hacia ALB interno (Backend)"
  from_port                = var.backend_port
  to_port                  = var.backend_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb_backend_sg_primary.id
}

resource "aws_security_group_rule" "alb_backend_ingress_from_frontend_primary" {
  type                     = "ingress"
  security_group_id        = aws_security_group.alb_backend_sg_primary.id
  description              = "Frontend hacia ALB interno"
  from_port                = var.backend_port
  to_port                  = var.backend_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.frontend_sg_primary.id
}

# Reglas ALB interno <-> instancias
resource "aws_security_group_rule" "alb_backend_egress_to_backend_primary" {
  type                     = "egress"
  security_group_id        = aws_security_group.alb_backend_sg_primary.id
  description              = "ALB interno hacia Backend"
  from_port                = var.backend_port
  to_port                  = var.backend_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.backend_sg_primary.id
}

resource "aws_security_group_rule" "backend_ingress_from_alb_backend_primary" {
  type                     = "ingress"
  security_group_id        = aws_security_group.backend_sg_primary.id
  description              = "ALB interno hacia Backend"
  from_port                = var.backend_port
  to_port                  = var.backend_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb_backend_sg_primary.id
}

# Reglas SSM via interfaces Endpoints (443)
# Egress desde instancias -> VPCE (SSM)
resource "aws_security_group_rule" "app_egress_to_vpce_443_primary" {
  for_each = local.app_instance_sg_primary

  type                     = "egress"
  security_group_id        = each.value
  description              = "Instancias ${each.key} hacia VPCE SSM (443)"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.vpce_sg_primary.id
}

# Ingress en VPCE desde instancias
resource "aws_security_group_rule" "vpce_ingress_from_apps_443_primary" {
  for_each = local.app_instance_sg_primary

  type                     = "ingress"
  security_group_id        = aws_security_group.vpce_sg_primary.id
  description              = "Instancias ${each.key} (443) hacia VPCE SSM"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = each.value
}

# Reglas DNS (53) desde instancias
resource "aws_security_group_rule" "app_egress_dns_upd_primary" {
  for_each = local.app_instance_sg_primary

  type              = "egress"
  security_group_id = each.value
  description       = "Instancias ${each.key} hacia DNS UDP (VPC resolver)"
  from_port         = 53
  to_port           = 53
  protocol          = "udp"
  cidr_blocks       = [local.vpc_resolver_cidr_primary]
}

resource "aws_security_group_rule" "app_egress_dns_tcp_primary" {
  for_each = local.app_instance_sg_primary

  type              = "egress"
  security_group_id = each.value
  description       = "Instancias ${each.key} hacia DNS TCP (VPC resolver)"
  from_port         = 53
  to_port           = 53
  protocol          = "tcp"
  cidr_blocks       = [local.vpc_resolver_cidr_primary]
}

# Reglas Egress a Internet (via NAT) para dependencias/repos externos
resource "aws_security_group_rule" "app_egress_https_internet_primary" {
  for_each = local.app_instance_sg_primary

  type              = "egress"
  security_group_id = each.value
  description       = "Instancias ${each.key} hacia Internet HTTPS (via NAT)"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
}
