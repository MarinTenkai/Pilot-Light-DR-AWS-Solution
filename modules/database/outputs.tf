output "db_instance_id" {
  value = var.is_replica ? aws_db_instance.replica[0].id : aws_db_instance.primary[0].id
}

output "db_instance_arn" {
  value = var.is_replica ? aws_db_instance.replica[0].arn : aws_db_instance.primary[0].arn
}

output "db_address" {
  value = var.is_replica ? aws_db_instance.replica[0].address : aws_db_instance.primary[0].address
}

output "db_endpoint" {
  value = var.is_replica ? aws_db_instance.replica[0].endpoint : aws_db_instance.primary[0].endpoint
}

output "db_port" {
  value = var.is_replica ? aws_db_instance.replica[0].port : aws_db_instance.primary[0].port
}
