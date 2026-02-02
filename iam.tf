## IAM Roles y Perfiles de Instancias para las Regiones Primaria y Secundaria

#Creamos el rol IAM para EC2 FRONTEND
resource "aws_iam_role" "ec2_frontend_role" {
  name               = "${terraform.workspace}-ec2-frontend-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

#Adjuntamos la política gestionada de AmazonSSMManagedInstanceCore al rol IAM EC2 FRONTEND
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_frontend_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

#Creamos el perfil de instancia IAM para EC2 FRONTEND
resource "aws_iam_instance_profile" "ec2_frontend_profile" {
  name = "${terraform.workspace}-ec2-frontend-profile"
  role = aws_iam_role.ec2_frontend_role.name
}

## IAM Role y Perfil de Instancias para Backend

#Creamos el rol IAM para EC2 BACKEND
resource "aws_iam_role" "ec2_backend_role" {
  name               = "${terraform.workspace}-ec2-backend-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

#Adjuntamos la política gestionada de AmazonSSMManagedInstanceCore al rol IAM EC2 BACKEND
resource "aws_iam_role_policy_attachment" "backend_ssm_core" {
  role       = aws_iam_role.ec2_backend_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

#Creamos el perfil de instancia IAM para EC2 BACKEND
resource "aws_iam_instance_profile" "ec2_backend_profile" {
  name = "${terraform.workspace}-ec2-backend-profile"
  role = aws_iam_role.ec2_backend_role.name
}

# resource "aws_iam_policy" "backend_read_db_secret" {
#   name   = "${terraform.workspace}-backend-read-db-secret"
#   policy = data.aws_iam_policy_document.backend_read_db_secret.json
# }

# resource "aws_iam_role_policy_attachment" "backend_read_db_secret_attach" {
#   role       = aws_iam_role.ec2_backend_role.name
#   policy_arn = aws_iam_policy.backend_read_db_secret.arn
# }
