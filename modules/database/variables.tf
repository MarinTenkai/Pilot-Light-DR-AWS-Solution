variable "name_prefix" { type = string }
variable "role" { type = string } # "primary" | "secondary"

variable "db_subnets" { type = list(string) }
variable "vpc_security_group_ids" { type = list(string) }

variable "engine_version" { type = string }
variable "instance_class" { type = string }

variable "allocated_storage" {
  type        = number
  description = "Solo aplica al primario; en réplicas puede heredarse."
  default     = 20
}

variable "storage_type" {
  type    = string
  default = "gp3"
}

variable "db_name" {
  type    = string
  default = "appdb"
}

variable "username" {
  type    = string
  default = "appuser"
}

variable "password" {
  type      = string
  default   = null
  sensitive = true

  validation {
    condition     = var.password == null || length(var.password) >= 12
    error_message = "Si defines password, debe tener al menos 12 caracteres."
  }
}

variable "port" {
  type    = number
  default = 5432
}

variable "multi_az" {
  type    = bool
  default = true
}

variable "backup_retention_period" {
  type    = number
  default = 1
}

variable "deletion_protection" {
  type    = bool
  default = false
}

variable "skip_final_snapshot" {
  type    = bool
  default = true
}

variable "final_snapshot_identifier" {
  type    = string
  default = null
}

variable "kms_key_id" {
  type        = string
  description = "KMS key ARN/ID para cifrado"
}

variable "is_replica" {
  type    = bool
  default = false
}

variable "replicate_source_db" {
  type        = string
  default     = null
  description = "Para cross-region replica: ARN del primario"
}

variable "apply_immediately" {
  type    = bool
  default = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
