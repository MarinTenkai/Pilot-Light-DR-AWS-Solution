#############################################################################
#############################################################################

#### Establecer la Región Primaria para producción ####
variable "primary_region" {
  description = "Región AWS primaria donde se despliega producción"
  type        = string
  default     = "eu-south-2" # España
}

#### Establecer la Región Secundaria recuperación de desastres ####
variable "secondary_region" {
  description = "Región AWS secundaria donde se despliega disaster recovery"
  type        = string
  default     = "eu-west-3" # París
}

#############################################################################
#############################################################################

#############################################################
###### Comunes para las Regiones Primaria y Secundaria ######
#############################################################

# Nombre del proyecto
variable "project_name" {
  description = "Nombre del proyecto (usado para naming y tags)"
  type        = string
  default     = "Pilot Light Disaster Recovery Solution"
}

# Número de Availability Zones a usar
variable "az_count" {
  description = "Número de Availability Zones a usar en la región"
  type        = number
  default     = 2
}

## Flow Logs Variables

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

#### ASGs Frontend & Backend comunes para Región Primaria y Secundaria

# Tipo de instancia para las instancias Frontend
variable "frontend_instance_type" {
  type    = string
  default = "t3.micro"
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

# Tipo de instancia para las instancias Backend
variable "backend_instance_type" {
  type    = string
  default = "t3.micro"
}

# Healthcheck path del ALB interno para la capa Backend
variable "backend_healthcheck_path" {
  type    = string
  default = "/"
}

# Puerto del servicio backend al que el Frontend debe poder conectarse.
variable "backend_port" {
  description = "Puerto del servicio backend al que el Frontend debe poder conectarse."
  type        = number
  default     = 8080
}

#############################################
###### Variables de la Región Primaria ######
#############################################

## Frontend para la Región Primaria

# min size del Auto Scaling Group en Frontend para la región Primaria
variable "frontend_min_size_primary" {
  type    = number
  default = 2
}

# max size del Auto Scaling Group en Frontend para la región Primaria
variable "frontend_max_size_primary" {
  type    = number
  default = 4
}

# desired capacity del Auto Scaling Group en Frontend para la región Primaria
variable "frontend_desired_capacity_primary" {
  type    = number
  default = 2
}

## Backend para la Región Primaria

# min size del Auto Scaling Group en Backend para la Región Primaria
variable "backend_min_size_primary" {
  type    = number
  default = 2
}

# max size del Auto Scaling Group en Backend para la Región Primaria
variable "backend_max_size_primary" {
  type    = number
  default = 4
}

# desired capacity del Auto Scaling Group en Backend para la Región Primaria
variable "backend_desired_capacity_primary" {
  type    = number
  default = 2
}

## Networking para la Región Primaria

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

#############################################
###### Variables de la Región Secundaria ######
#############################################

## Frontend Variables para la Región Secundaria 

# min size del Auto Scaling Group en Frontend para la Región Secundaria
variable "frontend_min_size_secondary" {
  type    = number
  default = 0 # 0 para estrategia Pilot Light, 1 para estrategia Warm Standby
}

# max size del Auto Scaling Group en Frontend para la Región Secundaria
variable "frontend_max_size_secondary" {
  type    = number
  default = 4
}

# desired capacity del Auto Scaling Group en Frontend para la Región Secundaria
variable "frontend_desired_capacity_secondary" {
  type    = number
  default = 0 # 0 para estrategia Pilot Light, 1 para estrategia Warm Standby
}

## Backend para la Región Secundaria

# min size del Auto Scaling Group en Backend para la región Secundaria
variable "backend_min_size_secondary" {
  type    = number
  default = 0 # 0 para estrategia Pilot Light, 1 para estrategia Warm Standby
}

# max size del Auto Scaling Group en Backend para la región Secundaria
variable "backend_max_size_secondary" {
  type    = number
  default = 4
}

# desired capacity del Auto Scaling en Backend para la Región Secundaria
variable "backend_desired_capacity_secondary" {
  type    = number
  default = 0 # 0 para estrategia Pilot Light, 1 para estrategia Warm Standby
}

## Networking para la Región Secundaria

# VPC cidrs para la Región Secundaria
variable "vpc_secondary_cidr" {
  description = "CIDR de la VPC de la Región Secundaria"
  type        = string
  default     = "10.10.0.0/16"
}

# Cidrs de subnets públicas para la Región Secundaria
variable "public_subnets_cidrs_secondary" {
  description = "Lista de CIDRs para subnets públicas (debe coincidir con az_count)"
  type        = list(string)
  default     = ["10.10.0.0/24", "10.10.1.0/24"]

  validation {
    condition     = length(var.public_subnets_cidrs_secondary) == var.az_count
    error_message = "public_subnet_cidrs debe tener exactamente ${var.az_count} elementos"
  }
}

# Cidrs de subnets privadas para la Región Secundaria
variable "private_subnets_cidrs_secondary" {
  description = "Lista de CIDRs para subnets privadas (debe coincidir con az_count)"
  type        = list(string)
  default     = ["10.10.10.0/24", "10.10.11.0/24"]

  validation {
    condition     = length(var.private_subnets_cidrs_secondary) == var.az_count
    error_message = "private_subnet_cidrs debe tener exactamente ${var.az_count} elementos"
  }
}

# Cidrs de subnets de base de datos para la Región Secundaria
variable "database_subnets_cidrs_secondary" {
  description = "Lista de CIDRs para subnets privadas de base de datos (debe coincidir con az_count)"
  type        = list(string)
  default     = ["10.10.20.0/24", "10.10.21.0/24"]

  validation {
    condition     = length(var.database_subnets_cidrs_secondary) == var.az_count
    error_message = "database_subnet_cidrs debe tener exactamente ${var.az_count} elementos"
  }
}







## RDS PostgreSQL (Multi-AZ) ##

variable "db_port" {
  description = "Puerto de la BD (5432 para postgresql, 3306 para mysql)"
  type        = number
  default     = 5432
}

variable "postgresql_instance_class" {
  description = "Clase de instancia RDS"
  type        = string
  default     = "db.t3.micro"
}

variable "postgresql_allocated_storage" {
  description = "Almacenamiento inicial (GB)"
  type        = number
  default     = 20
}

variable "postgresql_max_allocated_storage" {
  description = "Almacenamiento máximo autoscaling (GB)"
  type        = number
  default     = 100
}

variable "postgresql_db_name" {
  description = "Nombre de la base de datos inicial"
  type        = string
  default     = "appdb"
}

variable "postgresql_master_username" {
  description = "Usuario master"
  type        = string
  default     = "appadmin"
}
