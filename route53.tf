#############################################################################
######################## Route53 / DNS (Pilot Light) ########################
#############################################################################

variable "route53_zone_name" {
  description = "Nombre de la Hosted Zone pública en Route53. No requiere dominio comprado para crearse (modo demo). NO pongas punto final."
  type        = string
  default     = "pilotlight.invalid"
}

variable "route53_record_name" {
  description = "Subdominio para el entrypoint público (ej: app => app.pilotlight.invalid)."
  type        = string
  default     = "app"
}

variable "route53_health_check_type" {
  description = "Tipo de health check (HTTP o HTTPS)."
  type        = string
  default     = "HTTP"
}

variable "route53_health_check_port" {
  description = "Puerto del health check (para tu ALB HTTP normalmente 80)."
  type        = number
  default     = 80
}

variable "route53_health_check_path" {
  description = "Path del health check (ej: /, /health)."
  type        = string
  default     = "/"
}

variable "route53_health_check_request_interval" {
  description = "Intervalo del health check Route53 (10 o 30 segundos)."
  type        = number
  default     = 30
}

variable "route53_health_check_failure_threshold" {
  description = "Número de fallos consecutivos antes de marcar unhealthy."
  type        = number
  default     = 3
}

variable "route53_evaluate_target_health" {
  description = "Para Alias records: si true, Route53 evalúa el estado del target (ALB)."
  type        = bool
  default     = true
}


############################
# Route53 (Pilot Light DNS)
############################

# Descubrimos los ALB desde los ARNs que ya expone tu módulo frontend
data "aws_lb" "frontend_primary" {
  provider = aws.primary
  arn      = module.frontend_primary.alb_arn
}

data "aws_lb" "frontend_secondary" {
  provider = aws.secondary
  arn      = module.frontend_secondary.alb_arn
}

# Hosted Zone pública (modo demo o real)
resource "aws_route53_zone" "public" {
  provider = aws.primary

  name    = var.route53_zone_name
  comment = "Public Hosted Zone - ${var.project_name} (${terraform.workspace})"

  tags = merge(local.common_tags, {
    Tier = "DNS"
  })
}

# Health check contra ALB PRIMARIO
resource "aws_route53_health_check" "frontend_primary" {
  provider = aws.primary

  type          = var.route53_health_check_type
  fqdn          = data.aws_lb.frontend_primary.dns_name
  port          = var.route53_health_check_port
  resource_path = var.route53_health_check_path

  request_interval  = var.route53_health_check_request_interval
  failure_threshold = var.route53_health_check_failure_threshold

  tags = merge(local.common_tags, {
    Name = "${terraform.workspace}-frontend-primary-hc"
    Tier = "DNS"
  })
}

# Record PRIMARY (failover)
resource "aws_route53_record" "frontend_failover_primary" {
  provider = aws.primary

  zone_id = aws_route53_zone.public.zone_id
  name    = "${var.route53_record_name}.${var.route53_zone_name}"
  type    = "A"

  set_identifier = "${terraform.workspace}-primary"

  failover_routing_policy {
    type = "PRIMARY"
  }

  alias {
    name                   = data.aws_lb.frontend_primary.dns_name
    zone_id                = data.aws_lb.frontend_primary.zone_id
    evaluate_target_health = true
  }

  health_check_id = aws_route53_health_check.frontend_primary.id

  lifecycle {
    create_before_destroy = true
  }
}

# Record SECONDARY (failover)
resource "aws_route53_record" "frontend_failover_secondary" {
  provider = aws.primary

  zone_id = aws_route53_zone.public.zone_id
  name    = "${var.route53_record_name}.${var.route53_zone_name}"
  type    = "A"

  set_identifier = "${terraform.workspace}-secondary"

  failover_routing_policy {
    type = "SECONDARY"
  }

  alias {
    name                   = data.aws_lb.frontend_secondary.dns_name
    zone_id                = data.aws_lb.frontend_secondary.zone_id
    evaluate_target_health = false
  }

  lifecycle {
    create_before_destroy = true
  }
}
