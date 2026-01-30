##Common Variables (Both Regions)##

variable "project_name" {
  description = "Nombre del proyecto (usado para naming y tags)"
  type        = string
  default     = "pilot-light-dr"
}

variable "az_count" {
  description = "Número de Availability Zones a usar en la región"
  type        = number
  default     = 2
}

variable "key_name" {
  description = "Nombre del Key Pair en AWS"
  type        = string
  default     = "keypair-terraform"
}

variable "public_key_path" {
  description = "Ruta al archivo .pub de la clave pública"
  type        = string
  default     = ".ssh/pilot-light-dr/pilot-light-dr.pub"
}
#Flow Logs Variables

variable "flow_logs_traffic_type" {
  type        = string
  default     = "ALL"
  description = "Tipo de tráfico a capturar en los VPC Flow Logs (ALL, ACCEPT, REJECT)"
  validation {
    condition     = contains(["ALL", "ACCEPT", "REJECT"], var.flow_logs_traffic_type)
    error_message = "flow_logs_traffic_type debe ser ALL, ACCEPT o REJECT"
  }
}

variable "flow_logs_s3_prefix" {
  type    = string
  default = "vpc_flow-logs/"
}
##Primary Region Variables##

variable "primary_region" {
  description = "Región AWS primaria donde se despliega producción"
  type        = string
  default     = "eu-south-2" # España
}

variable "vpc_primary_cidr" {
  description = "CIDR de la VPC de la región primaria"
  type        = string
  default     = "10.10.0.0/16"
}

variable "public_subnets_cidrs_primary" {
  description = "Lista de CIDRs para subnets públicas (debe coincidir con az_count)"
  type        = list(string)
  default     = ["10.10.0.0/24", "10.10.1.0/24"]

  validation {
    condition     = length(var.public_subnets_cidrs_primary) == var.az_count
    error_message = "public_subnet_cidrs debe tener exactamente ${var.az_count} elementos"
  }
}

variable "private_subnets_cidrs_primary" {
  description = "Lista de CIDRs para subnets privadas (debe coincidir con az_count)"
  type        = list(string)
  default     = ["10.10.10.0/24", "10.10.11.0/24"]

  validation {
    condition     = length(var.private_subnets_cidrs_primary) == var.az_count
    error_message = "private_subnet_cidrs debe tener exactamente ${var.az_count} elementos"
  }
}

variable "database_subnets_cidrs_primary" {
  description = "Lista de CIDRs para subnets privadas de base de datos (debe coincidir con az_count)"
  type        = list(string)
  default     = ["10.10.20.0/24", "10.10.21.0/24"]

  validation {
    condition     = length(var.database_subnets_cidrs_primary) == var.az_count
    error_message = "database_subnet_cidrs debe tener exactamente ${var.az_count} elementos"
  }
}

variable "frontend_instance_type" {
  type    = string
  default = "t3.micro"
}

variable "frontend_min_size" {
  type    = number
  default = 1
}

variable "frontend_max_size" {
  type    = number
  default = 2
}

variable "frontend_desired_capacity" {
  type    = number
  default = 1
}

variable "frontend_port" {
  type    = number
  default = 80
}

variable "frontend_healthcheck_path" {
  type    = string
  default = "/"
}

variable "frontend_user_data_base64" {
  type        = string
  description = "User data en BASE64 para instancias frontend"
  default     = null
}

variable "backend_sg_id" {
  description = "Security Group ID del backend. Cuando sea null, no se crea la regla de egress Frontend->Backend"
  type        = string
  default     = null
}

variable "backend_port" {
  description = "Puerto del servicio backend al que el Frontend debe poder conectarse."
  type        = number
  default     = 8080
}

variable "key_name" {
  type        = string
  description = "Par de claves para SHH (Desactivado por defecto)"
  default     = null
}
##Secondary Region Variables##

variable "secondary_region" {
  description = "Región AWS secundaria donde se despliega disaster recovery"
  type        = string
  default     = "eu-west-3" # París
}
