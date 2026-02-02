data "aws_ssm_parameter" "backend_ami" {
  name = var.ami_ssm_parameter_name
}

locals {
  alb_name = "${var.role}-backend-alb"
  asg_name = "${var.role}-backend-asg"
  lt_name  = "${var.role}-backend-lt"

  default_user_data_base64 = base64encode(<<-EOF
    #!/bin/bash
    set -euxo pipefail

    mkdir -p /var/www/backend
    cat > /var/www/backend/index.html <<'HTML'
    <h1>OK - Backend Instance</h1>
    <p>Esta es una pagina de prueba servida desde las instancias Backends.</p>
    HTML

    nohup python3 -m http.server ${var.backend_port} --directory /var/www/backend >/var/log/backend-server.log 2>&1 &
  EOF
  )
}

# ALB interno para Backend
module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "10.5.0"

  name               = local.alb_name
  load_balancer_type = "application"
  internal           = true

  vpc_id          = var.vpc_id
  subnets         = var.private_subnets
  security_groups = [var.alb_sg_id]

  enable_deletion_protection = var.enable_deletion_protection

  listeners = {
    http_backend = {
      port     = var.backend_port
      protocol = "HTTP"
      forward  = { target_group_key = "backend" }
    }
  }

  target_groups = {
    backend = {
      name_prefix          = "tg-"
      protocol             = "HTTP"
      port                 = var.backend_port
      target_type          = "instance"
      deregistration_delay = 10
      create_attachment    = false

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

  tags = var.tags
}

# ASG Backend
module "asg" {
  source  = "terraform-aws-modules/autoscaling/aws"
  version = "9.1.0"

  name                = local.asg_name
  vpc_zone_identifier = var.private_subnets

  min_size         = var.min_size
  max_size         = var.max_size
  desired_capacity = var.desired_capacity

  health_check_type         = "ELB"
  health_check_grace_period = 180

  traffic_source_attachments = {
    backend = {
      traffic_source_identifier = module.alb.target_groups["backend"].arn
      traffic_source_type       = "elbv2"
    }
  }

  launch_template_name        = local.lt_name
  launch_template_description = "Backend LT"

  image_id      = data.aws_ssm_parameter.backend_ami.value
  instance_type = var.backend_instance_type

  iam_instance_profile_name = var.iam_instance_profile_name

  security_groups = [var.instance_sg_id]
  user_data       = filebase64(var.user_data_path)

  tags = merge(var.tags, {
    name = "${var.name_prefix}-${var.role}-backend-instance"
    tier = "Backend"
  })
}
