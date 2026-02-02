#### Data comunes para las regiones Primaria y Secundaria ####

# Identificador de la cuenta
data "aws_caller_identity" "current" {}

# AMI para instancias EC2 (Amazon Linux 2)
data "aws_ssm_parameter" "amazon_linux_2_ami" {
  provider = aws.primary
  name     = "/aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-gp2"
}

#Creamos la política de asunción de rol para EC2
data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

#Creamos la política de asunción de rol para EC2 BACKEND ~!!!HAY QUE CAMBIAR!!!~
# data "aws_iam_policy_document" "backend_read_db_secret" {
#   statement {
#     sid    = "ReadRdsManagedSecret"
#     effect = "Allow"
#     actions = [
#       "secretsmanager:GetSecretValue",
#       "secretsmanager:DescribeSecret"
#     ]
#     resources = [
#       aws_db_instance.postgresql.master_user_secret[0].secret_arn
#     ]
#   }
# }

#### Locals exclusivos para la Región Primaria ####

#Extrae la lista de zonas disponibles en la region seleccionada
data "aws_availability_zones" "primary" {
  state = "available"
}

#### Locals exclusivos para la Región Secundaria ####

data "aws_availability_zones" "secondary" {
  provider = aws.secondary
  state    = "available"
}
