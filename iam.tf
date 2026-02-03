#### IAM Roles y Perfiles de Instancias ####
############################################

## Comunes ## 

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

## Frontend ##

#Creamos el rol IAM para EC2 Frontend
resource "aws_iam_role" "ec2_frontend_role" {
  name               = "${terraform.workspace}-ec2-frontend-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

#Adjuntamos la política gestionada de AmazonSSMManagedInstanceCore al rol IAM EC2 Frontend
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_frontend_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

#Creamos el perfil de instancia IAM para EC2 Frontend
resource "aws_iam_instance_profile" "ec2_frontend_profile" {
  name = "${terraform.workspace}-ec2-frontend-profile"
  role = aws_iam_role.ec2_frontend_role.name
}

## Backend ##

#Creamos el rol IAM para EC2 Backend
resource "aws_iam_role" "ec2_backend_role" {
  name               = "${terraform.workspace}-ec2-backend-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

#Adjuntamos la política gestionada de AmazonSSMManagedInstanceCore al rol IAM EC2 Backend
resource "aws_iam_role_policy_attachment" "backend_ssm_core" {
  role       = aws_iam_role.ec2_backend_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

#Creamos el perfil de instancia IAM para EC2 Backend
resource "aws_iam_instance_profile" "ec2_backend_profile" {
  name = "${terraform.workspace}-ec2-backend-profile"
  role = aws_iam_role.ec2_backend_role.name
}
