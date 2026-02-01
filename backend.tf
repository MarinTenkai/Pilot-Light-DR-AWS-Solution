############################################
###### Recursos de la Región Primaria ######
############################################

## ALB interno para Backend de la región primaria

module "alb_backend_primary" {
  source  = "terraform-aws-modules/alb/aws"
  version = "10.5.0"

  providers = {
    aws = aws.primary
  }

  name               = "${terraform.workspace}-backend-alb"
  load_balancer_type = "application"
  internal           = true

  vpc_id          = module.network_primary.id
  subnets         = module.network_primary.private_subnets
  security_groups = [aws_security_group.alb_backend_sg_primary.id]

  enable_deletion_protection = false

  listeners = {
    http_backend = {
      port     = var.backend_port
      protocol = "HTTP"

      forward = {
        target_group_key = "backend"
      }
    }
  }

  target_groups = {
    backend = {
      name_prefix          = "tg-"
      protocol             = "HTTP"
      port                 = var.backend_port
      target_type          = "instance"
      deregistration_delay = 10

      create_attachment = false

      health_check = {
        enabled             = true
        path                = var.backend_healthcheck_path
        protocol            = "HTTP"
        matcher             = "200-399"
        interval            = 30
        timeout             = 5
        healthy_threshold   = 2
        unhealthy_threshold = 2
      }
    }
  }
}

## Auto Scaling Group para instancias Backend de la región primaria
module "autoscaling_backend_primary" {
  source  = "terraform-aws-modules/autoscaling/aws"
  version = "9.1.0"

  providers = {
    aws = aws.primary
  }

  name = "${terraform.workspace}-backend-asg"

  vpc_zone_identifier = module.network_primary.private_subnets

  min_size         = var.backend_min_size_primary
  max_size         = var.backend_max_size_primary
  desired_capacity = var.backend_desired_capacity_primary

  health_check_type         = "ELB"
  health_check_grace_period = 180

  traffic_source_attachments = {
    backend = {
      traffic_source_identifier = module.alb_backend_primary.target_groups["backend"].arn
      traffic_source_type       = "elbv2"
    }
  }

  launch_template_name        = "${terraform.workspace}-backend-lt"
  launch_template_description = "Backend LT"

  image_id      = data.aws_ssm_parameter.amazon_linux_2_ami.value
  instance_type = var.backend_instance_type

  iam_instance_profile_name = aws_iam_instance_profile.ec2_backend_profile.name

  security_groups = [aws_security_group.backend_sg_primary.id]
  user_data       = local.backend_user_data_primary

  tags = merge(local.common_tags, local.primary_tags, {
    name = "${terraform.workspace}-backend-instance"
    tier = "Backend"
  })
}

##############################################
###### Recursos de la Región Secundaria ######
##############################################
