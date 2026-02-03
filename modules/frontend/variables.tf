variable "name_prefix" { type = string } # ex: "test" | "dev" | "prod"
variable "role" { type = string }        # ex: "primary" | "secondary"

# Network inputs (del modulo network)
variable "vpc_id" { type = string }
variable "public_subnets" { type = list(string) }
variable "private_subnets" { type = list(string) }

# IDs de los grupos de seguridad definidos en el módulo Network y exportados al root mediante outputs
variable "alb_sg_id" { type = string }
variable "instance_sg_id" { type = string }

# ASG sizing (diferente por región)
variable "min_size" { type = number }
variable "max_size" { type = number }
variable "desired_capacity" { type = number }

# Nombre del IAM instance profile
variable "iam_instance_profile_name" { type = string }

# Path del user data, por defecto se encuentra en /userdata/frontend/default.sh y /userdata/backend/default.sh
variable "user_data_path" { type = string }

# Tags ya fusionadas desde el root (common + role)
variable "tags" {
  type    = map(string)
  default = {}
}

# Puerto por defecto, es sobre escrito por variable del mismo nombre en variables.tf del root
variable "frontend_port" {
  type    = number
  default = 80
}

# Path del healthcheck por defecto, es sobre escrito por variable del mismo nombre en variables.tf del root
variable "frontend_healthcheck_path" {
  type    = string
  default = "/"
}

# Tipo de instancia por defecto, es sobre escrito por variable del mismo nombre en variables.tf del root
variable "frontend_instance_type" {
  type    = string
  default = "t3.micro"
}

# Protección contra eliminación por defecto activada, es sobre escrito por variable del mismo nombre en variables.tf del root
variable "enable_deletion_protection" {
  type    = bool
  default = true
}

# Parámetro por defecto, se puede sobre escribir desde la variable correspondiente en variables.tf del directorio root
variable "ami_ssm_parameter_name" {
  type    = string
  default = "/aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-gp2"
}
