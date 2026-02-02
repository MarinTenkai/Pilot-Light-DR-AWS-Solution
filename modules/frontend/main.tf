# AMI para instancias EC2 (Amazon Linux 2)
data "aws_ssm_parameter" "frontend_ami" {
  name = var.ami_ssm_parameter_name
}

locals {
  # Nombres (puedes incluir role para que sea más claro en consola)
  alb_name = "${var.role}-frontend-alb"
  asg_name = "${var.role}-frontend-asg"
  lt_name  = "${var.role}-frontend-lt"

  default_user_data_base64 = base64encode(<<-EOF
    #!/bin/bash
    set -euxo pipefail

    mkdir -p /var/www/html
    cat > /var/www/html/index.html <<'HTML'
    <h1>OK - Frontend Instance</h1>
    <p>Esta es una pagina de prueba servida desde las instancias Frontends.</p>
    HTML

    nohup python3 -m http.server ${var.frontend_port} --directory /var/www/html >/var/log/frontend-server.log 2>&1 &
  EOF
  )
}

# ALB público
module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "10.5.0"

  name                       = local.alb_name
  load_balancer_type         = "application"
  vpc_id                     = var.vpc_id
  subnets                    = var.public_subnets
  security_groups            = [var.alb_sg_id]
  enable_deletion_protection = var.enable_deletion_protection

  listeners = {
    http = {
      port     = 80
      protocol = "HTTP"
      forward  = { target_group_key = "frontend" }
    }
  }

  target_groups = {
    frontend = {
      name_prefix          = "tg-"
      protocol             = "HTTP"
      port                 = var.frontend_port
      target_type          = "instance"
      deregistration_delay = 10
      create_attachment    = false

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

  tags = var.tags
}

# ASG Frontend
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
    frontend = {
      traffic_source_identifier = module.alb.target_groups["frontend"].arn
      traffic_source_type       = "elbv2"
    }
  }

  launch_template_name        = local.lt_name
  launch_template_description = "Frontend LT"

  image_id      = data.aws_ssm_parameter.frontend_ami.value
  instance_type = var.frontend_instance_type

  iam_instance_profile_name = var.iam_instance_profile_name
  security_groups           = [var.instance_sg_id]

  user_data = filebase64(var.user_data_path)

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-${var.role}-frontend-instance"
    Tier = "Frontend"
  })
}
