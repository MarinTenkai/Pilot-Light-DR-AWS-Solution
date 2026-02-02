variable "name_prefix" { type = string } # terraform.workspace
variable "role" { type = string }        # "primary" | "secondary"

# Network inputs (del módulo network)
variable "vpc_id" { type = string }
variable "private_subnets" { type = list(string) }

# SGs (del módulo network)
variable "alb_sg_id" { type = string }      # alb_backend_sg_id
variable "instance_sg_id" { type = string } # backend_sg_id

# ASG sizing (diferente por región)
variable "min_size" { type = number }
variable "max_size" { type = number }
variable "desired_capacity" { type = number }

# Backend config
variable "backend_port" {
  type    = number
  default = 8080
}

variable "backend_healthcheck_path" {
  type    = string
  default = "/"
}

variable "backend_instance_type" {
  type    = string
  default = "t3.micro"
}

variable "enable_deletion_protection" {
  type    = bool
  default = false
}

# IAM instance profile (lo creas en root/global)
variable "iam_instance_profile_name" {
  type = string
}

variable "ami_ssm_parameter_name" {
  type    = string
  default = "/aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-gp2"
}

variable "user_data_path" { type = string }

# Tags ya fusionadas desde el root (common + role)
variable "tags" {
  type    = map(string)
  default = {}
}
