variable "name_prefix" {
  type = string
}

# "primary" | "secondary"
variable "role" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "azs" {
  type = list(string)
}

variable "public_subnets" {
  type = list(string)
}

variable "private_subnets" {
  type = list(string)
}

variable "database_subnets" {
  type = list(string)
}

variable "enable_nat_gateway" {
  type    = bool
  default = true
}

variable "one_nat_gateway_per_az" {
  type    = bool
  default = true
}

variable "single_nat_gateway" {
  type    = bool
  default = false
}

variable "flow_logs_traffic_type" {
  type    = string
  default = "ALL"
}

variable "flow_logs_s3_prefix" {
  type    = string
  default = "vpc_flow-logs/"
}

variable "flow_logs_force_destroy" {
  type    = bool
  default = true
}

variable "ssm_vpce_services" {
  type    = set(string)
  default = ["ssm", "ec2messages", "ssmmessages"]
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "public_subnet_tags" {
  type    = map(string)
  default = {}
}

variable "private_subnet_tags" {
  type    = map(string)
  default = {}
}

variable "database_subnet_tags" {
  type    = map(string)
  default = {}
}

# Puerto del ALB para la capa Frontend
variable "frontend_port" {
  type    = number
  default = 80
}

# Puerto del servicio backend al que el Frontend debe poder conectarse.
variable "backend_port" {
  description = "Puerto del servicio backend al que el Frontend debe poder conectarse."
  type        = number
  default     = 8080
}
