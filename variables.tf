#### Variables comunes para la región primaria y secundaria ####

# Nombre del proyecto
variable "project_name" {
  description = "Nombre del proyecto (usado para naming y tags)"
  type        = string
  default     = "pilot-light-dr"
}

# Número de Availability Zones a usar
variable "az_count" {
  description = "Número de Availability Zones a usar en la región"
  type        = number
  default     = 2
}

# variable "key_name" {
#   description = "Nombre del Key Pair en AWS"
#   type        = string
#   default     = "keypair-terraform"
# }

# variable "public_key_path" {
#   description = "Ruta al archivo .pub de la clave pública"
#   type        = string
#   default     = ".ssh/pilot-light-dr/pilot-light-dr.pub"
# }
#Flow Logs Variables

# Tipo de tráfico a capturar en los VPC Flow Logs
variable "flow_logs_traffic_type" {
  type        = string
  default     = "ALL"
  description = "Tipo de tráfico a capturar en los VPC Flow Logs (ALL, ACCEPT, REJECT)"
  validation {
    condition     = contains(["ALL", "ACCEPT", "REJECT"], var.flow_logs_traffic_type)
    error_message = "flow_logs_traffic_type debe ser ALL, ACCEPT o REJECT"
  }
}

# Prefix dentro del bucket S3 para los VPC Flow Logs
variable "flow_logs_s3_prefix" {
  type    = string
  default = "vpc_flow-logs/"
}

#### Variables de la región primaria ####

# Establecer la región primaria
variable "primary_region" {
  description = "Región AWS primaria donde se despliega producción"
  type        = string
  default     = "eu-south-2" # España
}

# VPC cidrs para la región primaria
variable "vpc_primary_cidr" {
  description = "CIDR de la VPC de la región primaria"
  type        = string
  default     = "10.10.0.0/16"
}

# Cidrs de subnets públicas para la región primaria
variable "public_subnets_cidrs_primary" {
  description = "Lista de CIDRs para subnets públicas (debe coincidir con az_count)"
  type        = list(string)
  default     = ["10.10.0.0/24", "10.10.1.0/24"]

  validation {
    condition     = length(var.public_subnets_cidrs_primary) == var.az_count
    error_message = "public_subnet_cidrs debe tener exactamente ${var.az_count} elementos"
  }
}

# Cidrs de subnets privadas para la región primaria
variable "private_subnets_cidrs_primary" {
  description = "Lista de CIDRs para subnets privadas (debe coincidir con az_count)"
  type        = list(string)
  default     = ["10.10.10.0/24", "10.10.11.0/24"]

  validation {
    condition     = length(var.private_subnets_cidrs_primary) == var.az_count
    error_message = "private_subnet_cidrs debe tener exactamente ${var.az_count} elementos"
  }
}

# Cidrs de subnets de base de datos para la región primaria
variable "database_subnets_cidrs_primary" {
  description = "Lista de CIDRs para subnets privadas de base de datos (debe coincidir con az_count)"
  type        = list(string)
  default     = ["10.10.20.0/24", "10.10.21.0/24"]

  validation {
    condition     = length(var.database_subnets_cidrs_primary) == var.az_count
    error_message = "database_subnet_cidrs debe tener exactamente ${var.az_count} elementos"
  }
}

## Frontend Variables

# Tipo de instancia para las instancias Frontend
variable "frontend_instance_type" {
  type    = string
  default = "t3.micro"
}

# Auto Scaling Group Variables para Frontend
variable "frontend_min_size" {
  type    = number
  default = 1
}

# Auto Scaling max size para Frontend
variable "frontend_max_size" {
  type    = number
  default = 2
}

# Auto Scaling desired capacity para Frontend
variable "frontend_desired_capacity" {
  type    = number
  default = 1
}

# Puerto del ALB para la capa Frontend
variable "frontend_port" {
  type    = number
  default = 80
}

# Healthcheck path del ALB para la capa Frontend
variable "frontend_healthcheck_path" {
  type    = string
  default = "/"
}

# Security Group ID del backend. Cuando sea null, no se crea la regla de egress Frontend->Backend


# Puerto del servicio backend al que el Frontend debe poder conectarse.
variable "backend_port" {
  description = "Puerto del servicio backend al que el Frontend debe poder conectarse."
  type        = number
  default     = 8080
}


#### Secondary Region Variables ####

variable "secondary_region" {
  description = "Región AWS secundaria donde se despliega disaster recovery"
  type        = string
  default     = "eu-west-3" # París
}
