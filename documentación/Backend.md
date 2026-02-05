## 1) Propósito del módulo `modules/backend`

El módulo `backend` implementa la **capa de aplicación** (tier Backend) dentro de **una región**. Sus responsabilidades son:

1. Crear un **ALB interno (private / internal)** en **subredes privadas**.
    
2. Definir un **Target Group** para el backend con health checks.
    
3. Crear un **Auto Scaling Group (ASG)** que lanza instancias EC2 en **subredes privadas**, registrándolas en el target group del ALB interno.
    
4. Obtener la **AMI** desde **SSM Parameter Store** (para no hardcodear AMIs por región).
    
5. Inyectar `user_data` desde un fichero configurable (por defecto un servidor HTTP simple para test).
    

Este módulo forma el “eslabón” entre:

- **Frontend → ALB interno → Backend**, donde el **Frontend** consume el endpoint interno del ALB para hablar con el backend.
    
- **Backend → RDS**, pero **la conectividad a RDS se controla** desde el módulo `network` (SG backend → SG db).
    

> Al igual que el módulo frontend, el backend **no crea SGs**: los recibe del módulo `network` para mantener separación de responsabilidades.

---

## 2) Entradas del módulo (`modules/backend/variables.tf`)

### Identidad / naming

- **`name_prefix`**: prefijo de entorno (`dev`, `prod`, etc.). En root se usa `terraform.workspace`.
    
- **`role`**: `"primary"` o `"secondary"`. Se usa para nombrar recursos (`primary-backend-alb`, etc.).
    

### Inputs de red (del módulo `network`)

- **`vpc_id`**: VPC donde se despliegan ALB interno y ASG.
    
- **`private_subnets`**: subredes privadas usadas tanto por el ALB interno como por el ASG.
    

> El backend **no usa subredes públicas** en ningún punto (ALB internal).

### Seguridad (SGs definidos por `network`)

- **`alb_sg_id`**: SG del ALB interno del backend.
    
- **`instance_sg_id`**: SG de las instancias backend.
    

Modelo esperado (definido en `network/security.tf`):

- `frontend_sg` → `alb_backend_sg` en `backend_port`
    
- `alb_backend_sg` → `backend_sg` en `backend_port`
    

### Escalado (ASG sizing)

- **`min_size`**, **`max_size`**, **`desired_capacity`**: dimensionamiento del ASG.
    
    - Secundaria puede ir a 0/0 (Pilot Light).
        

### EC2 Launch config

- **`backend_instance_type`**: tipo de instancia (default `t3.micro`).
    
- **`iam_instance_profile_name`**: instance profile (en root se asocia a SSM).
    
- **`ami_ssm_parameter_name`**: parámetro SSM que resuelve la AMI.
    
- **`user_data_path`**: ruta a script de bootstrap (se carga en base64).
    

### Health & listener

- **`backend_port`**: puerto del servicio backend (default `8080`).
    
- **`backend_healthcheck_path`**: path del health check (default `/`).
    

### Protección

- **`enable_deletion_protection`**: protección contra borrado del ALB interno.
    

### Tags

- **`tags`**: tags fusionados desde root (common + role).
    

---

## 3) Qué hace el módulo (`modules/backend/main.tf`)

### 3.1 AMI dinámica desde SSM
```hcl
data "aws_ssm_parameter" "backend_ami" {   name = var.ami_ssm_parameter_name }
```
- Permite usar la misma configuración en distintas regiones sin cambiar AMI IDs.
    
- Por defecto apunta a Amazon Linux 2 en SSM.
    

### 3.2 Naming local (por rol)
```hcl
locals {   
	alb_name = "${var.role}-backend-alb"   
	asg_name = "${var.role}-backend-asg"   
	lt_name  = "${var.role}-backend-lt"   
	... 
}
```
### 3.3 `default_user_data_base64` (definido pero no usado)

Al igual que en frontend, el módulo define un `default_user_data_base64` pero **no se utiliza** porque el ASG siempre hace:
```hcl
user_data = filebase64(var.user_data_path)
```

---

## 4) ALB interno (privado) — `module "alb"`
```hcl
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
	... 
}
```
### 4.1 `internal = true` (punto clave)

- Hace que el ALB sea **solo accesible dentro de la VPC**.
    
- Su DNS (`alb_dns_name`) resuelve a IPs privadas.
    
- Este ALB actúa como “API Gateway interno” entre frontend y backend.
    
### 4.2 Subredes privadas

- `subnets = var.private_subnets` → no hay superficie de exposición pública.
    
### 4.3 Listener en `backend_port`
```hcl
listeners = {   
	http_backend = {     
	port     = var.backend_port     
	protocol = "HTTP"     
	forward  = { target_group_key = "backend" }   
	} 
}
```
- Expone el puerto del backend internamente (por defecto 8080).
    
- El Frontend debe hablar contra este ALB (y la SG del frontend permite egress a `backend_port` hacia el SG del ALB interno).
    

### 4.4 Target Group `backend`
```hcl
target_groups = {   
	backend = {     
		protocol    = "HTTP"     
		port        = var.backend_port     
		target_type = "instance"     
		create_attachment = false      
		health_check = {       
			path     = var.backend_healthcheck_path       
			matcher  = "200-399"       
		...     
		}   
	} 
}
```
Puntos clave:

- `target_type = "instance"`: se registran instancias EC2.
    
- `create_attachment = false`: el registro se hace desde el ASG.
    
- Health check configurable (path/thresholds).
    

---

## 5) Auto Scaling Group (Backend) — `module "asg"`
```hcl
module "asg" {   
	source  = "terraform-aws-modules/autoscaling/aws"   
	version = "9.1.0"    
	name                = local.asg_name   
	vpc_zone_identifier = var.private_subnets   
	... 
}
```
### 5.1 Ubicación de instancias

- `vpc_zone_identifier = var.private_subnets`: instancias en privadas.
    
- No se asocia IP pública ni se exponen a Internet.
    

### 5.2 Capacidad y modo DR

- `min_size`, `max_size`, `desired_capacity` vienen del root.
    
- En secundaria (Pilot Light), normalmente `desired=0`:
    
    - No habrá targets sanos hasta que se escale el ASG.
        
    - El ALB interno seguirá existiendo (pero sin targets).
        

### 5.3 Health check del ASG ligado al ALB
```hcl
health_check_type         = "ELB" health_check_grace_period = 180
```

- El ASG considera “salud” la del target group del ALB interno.
    
- El grace period evita churn durante arranque.
    

### 5.4 Asociación ASG ↔ Target Group
```hcl
traffic_source_attachments = {   
	backend = {     
		traffic_source_identifier = module.alb.target_groups["backend"].arn     
		traffic_source_type       = "elbv2"   
	} 
}
```
Esto automatiza:

- registro de instancias en el TG al escalar
    
- deregistro al terminar instancias
    

### 5.5 Launch Template (vía módulo autoscaling)
```hcl
launch_template_name        = local.lt_name 
launch_template_description = "Backend LT"  
image_id      = data.aws_ssm_parameter.backend_ami.value 
instance_type = var.backend_instance_type  
iam_instance_profile_name = var.iam_instance_profile_name 
security_groups           = [var.instance_sg_id] 
user_data                 = filebase64(var.user_data_path)
```
- AMI dinámica desde SSM
    
- SG de instancias backend definido en `network`
    
- IAM profile (SSM)
    
- User data desde fichero (por defecto levanta un HTTP server en 8080)
    

### 5.6 Tags en instancias
```hcl
tags = merge(var.tags, {   name = "${var.name_prefix}-${var.role}-backend-instance"   tier = "Backend" })
```

> Nota técnica: aquí las keys son `name` y `tier` (minúsculas), mientras en frontend se usan `Name` y `Tier`. No rompe nada, pero para consistencia de tagging suele preferirse una convención única.

---

## 6) Outputs del módulo (`modules/backend/outputs.tf`)

- **`alb_dns_name`**: DNS del ALB interno (solo resoluble dentro de la VPC).
    
- **`alb_arn`**: ARN del ALB (útil para data sources o inspección).
    
- **`backend_target_group_arn`**: ARN del TG del backend (debug/operación).
    
- **`asg_name`**: nombre del ASG (operación: escalar durante failover, etc).
    

---

## 7) Invocación del módulo backend en el root (`main.tf`)

Se invoca dos veces: `backend_primary` y `backend_secondary`.

### 7.1 `module "backend_primary"`
#### Provider (región primaria):
```hcl
providers = { aws = aws.primary }
```
#### Dependencias del módulo `network_primary`:
```hcl
vpc_id          = module.network_primary.vpc_id 
private_subnets = module.network_primary.private_subnets  
alb_sg_id      = module.network_primary.alb_backend_sg_id 
instance_sg_id = module.network_primary.backend_sg_id
```
#### Capacidad activa:
```hcl
min_size         = var.backend_min_size_primary 
desired_capacity = var.backend_desired_capacity_primary
```
#### Config servicio:
```hcl
backend_port             = var.backend_port 
backend_healthcheck_path = var.backend_healthcheck_path 
backend_instance_type    = var.backend_instance_type
```
#### IAM Profile:
```hcl
iam_instance_profile_name = aws_iam_instance_profile.ec2_backend_profile.name
```
#### AMI y user-data:
```hcl
ami_ssm_parameter_name = var.backend_ami_ssm_parameter_name 
user_data_path         = var.backend_user_data_path
```
#### Protección + tags:
```hcl
enable_deletion_protection = var.enable_deletion_protection 
tags = merge(local.common_tags, local.primary_tags)
```
### 7.2 `module "backend_secondary"`

Misma estructura, pero:
- Provider `aws.secondary`
- Usa outputs `module.network_secondary.*`
- Dimensionamiento Pilot Light por defecto:
```hcl
min_size         = var.backend_min_size_secondary   # 0 desired_capacity = var.backend_desired_capacity_secondary # 0
```
- Tags con `local.secondary_tags`

---

## 8) Implicaciones de diseño (solo backend, relevantes para DR)

1. **El backend siempre es privado**
    

- El ALB interno no expone tráfico a Internet.
    
- La única “puerta” hacia backend desde el exterior es el frontend (a través del SG chain).
    

2. **Health checks y estabilidad**
- `ELB` health check en ASG ayuda a reemplazar instancias que no pasan health check del TG.
    
- El health check path `/` es correcto para el server de prueba, pero para una app real conviene endpoint específico (`/health`, `/ready`, etc.).
