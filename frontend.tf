############################################
###### Recursos de la Región Primaria ######
############################################

## ALB público para Frontend de la región primaria

module "alb_frontend_primary" {
  source  = "terraform-aws-modules/alb/aws"
  version = "10.5.0"

  providers = {
    aws = aws.primary
  }

  name                       = "${terraform.workspace}-alb"
  load_balancer_type         = "application"
  vpc_id                     = module.network_primary.vpc_id
  subnets                    = module.network_primary.public_subnets
  security_groups            = [aws_security_group.alb_frontend_sg_primary.id]
  enable_deletion_protection = false

  # Listener HTTP :80
  listeners = {
    http = {
      port     = 80
      protocol = "HTTP"

      forward = {
        target_group_key = "frontend"
      }
    }
  }

  # Target Groups para el ASG de Frontend

  target_groups = {
    frontend = {
      name_prefix          = "tg-"
      protocol             = "HTTP"
      port                 = var.frontend_port
      target_type          = "instance"
      deregistration_delay = 10

      create_attachment = false

      health_check = {
        enabled             = true
        path                = var.frontend_healthcheck_path
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

## Auto Scaling Group para instancias Frontend de la región primaria

module "autoscaling_frontend_primary" {
  source  = "terraform-aws-modules/autoscaling/aws"
  version = "9.1.0"

  providers = {
    aws = aws.primary
  }

  name = "${terraform.workspace}-frontend-asg"

  # Subnets privadas (2 AZs)
  vpc_zone_identifier = module.network_primary.private_subnets

  min_size         = var.frontend_min_size_primary
  max_size         = var.frontend_max_size_primary
  desired_capacity = var.frontend_desired_capacity_primary

  # Health checks desde ALB
  health_check_type         = "ELB"
  health_check_grace_period = 180

  # Adjunta el ASG al target group del ALB
  traffic_source_attachments = {
    frontend = {
      traffic_source_identifier = module.alb_frontend_primary.target_groups["frontend"].arn
      traffic_source_type       = "elbv2"
    }
  }

  # Launch Template para las instancias Frontend
  launch_template_name        = "${terraform.workspace}-frontend-lt"
  launch_template_description = "Frontend LT"

  image_id      = data.aws_ssm_parameter.amazon_linux_2_ami.value
  instance_type = var.frontend_instance_type

  #Asignamos el perfil de instancia SSM
  iam_instance_profile_name = aws_iam_instance_profile.ec2_frontend_profile.name

  # SG de las instancias
  security_groups = [aws_security_group.frontend_sg_primary.id]

  # user data
  user_data = local.frontend_user_data

  # Etiquetas en instancias
  tags = merge(local.common_tags, local.primary_tags, {
    Name = "${terraform.workspace}-frontend-instance"
    Tier = "Frontend"
  })
}

##############################################
###### Recursos de la Región Secundaria ######
##############################################
