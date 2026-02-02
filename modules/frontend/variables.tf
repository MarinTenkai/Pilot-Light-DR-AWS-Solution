variable "name_prefix" { type = string } # terraform.workspace
variable "role" { type = string }        # "primary" | "secondary"

# Network inputs (vienen del modulo network)
variable "vpc_id" { type = string }
variable "public_subnets" { type = list(string) }
variable "private_subnets" { type = list(string) }

# SGs (vienen del modulo network)
variable "alb_sg_id" { type = string }
variable "instance_sg_id" { type = string }

# ASG sizing (diferente por región)
variable "min_size" { type = number }
variable "max_size" { type = number }
variable "desired_capacity" { type = number }

# Frontend app config
variable "frontend_port" {
  type    = number
  default = 80
}

variable "frontend_healthcheck_path" {
  type    = string
  default = "/"
}

variable "frontend_instance_type" {
  type    = string
  default = "t3.micro"
}

# IAM instance profile (lo creas en root/global)
variable "iam_instance_profile_name" { type = string }

# Opcional: sobrescribir AMI (si no, se obtiene por SSM en la región del provider)
variable "image_id_override" {
  description = "Si se define, reemplaza COMPLETAMENTE el AMI del módulo. Debe ser ami-xxxx"
  type        = string
  default     = null
}

# Opcional: sobrescribir user_data ya en base64 (si no, se genera dentro del módulo)
variable "user_data_base64_override" {
  description = "Si se define, reemplaza COMPLETAMENTE el user_data por defecto del módulo. Debe venir ya en Base64"
  type        = string
  default     = null
}

# Tags comunes/role ya fusionadas desde el root
variable "tags" {
  type    = map(string)
  default = {}
}

# Opcional (si quieres controlar esto desde root)
variable "enable_deletion_protection" {
  type    = bool
  default = false
}
