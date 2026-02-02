output "alb_dns_name" {
  value = module.alb.dns_name
}

output "alb_arn" {
  value = module.alb.arn
}

output "backend_target_group_arn" {
  value = module.alb.target_groups["backend"].arn
}

output "asg_name" {
  value = module.asg.autoscaling_group_name
}
