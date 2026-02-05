## 1) Propósito del módulo `modules/frontend`

El módulo `frontend` implementa la **capa de presentación** de la arquitectura (tier Frontend) en **una región** concreta y deja listo el “entry point” regional para Route 53:

1. Crea un **ALB público (internet-facing)** en **subredes públicas**.
    
2. Define un **Target Group** con health check para el frontend.
    
3. Crea un **Auto Scaling Group (ASG)** que lanza instancias EC2 en **subredes privadas**, y las registra como targets del ALB.
    
4. Obtiene la **AMI** de Amazon Linux 2 desde **SSM Parameter Store** (para evitar hardcodear AMI IDs por región).
    
5. Inyecta `user_data` desde un fichero configurable (por defecto un server HTTP muy simple).
    

> Este módulo no define Security Groups: **los recibe** del módulo `network`, manteniendo separación de responsabilidades.

---

## 2) Entradas del módulo (`modules/frontend/variables.tf`)

### Identidad y naming

- **`name_prefix`**: prefijo del entorno (ej: `dev`, `prod`). En el root se pasa `terraform.workspace`.
    
- **`role`**: `"primary"` o `"secondary"`. Se utiliza para nombrar recursos (`primary-frontend-alb`, etc.).
    

### Inputs de red (del módulo `network`)

- **`vpc_id`**: VPC donde se desplegará el ALB y el ASG.
    
- **`public_subnets`**: subredes públicas para el ALB público.
    
- **`private_subnets`**: subredes privadas donde vivirán las instancias del ASG.
    

### Seguridad (SGs definidos por `network`)

- **`alb_sg_id`**: SG del ALB público (internet → ALB).
    
- **`instance_sg_id`**: SG de instancias frontend (ALB → frontend).
    

> Esto implementa el “contrato” de seguridad: el módulo `frontend` asume que el SG ya permite el flujo correcto y solo lo consume.

### Escalado (ASG sizing)

- **`min_size`**, **`max_size`**, **`desired_capacity`**: dimensionamiento del ASG.
    
    - En secundaria puede ser 0/0 (Pilot Light) o >0 (Warm Standby).
        

### EC2 Launch config

- **`frontend_instance_type`**: tipo de instancia (por defecto `t3.micro`).
    
- **`iam_instance_profile_name`**: instance profile para EC2 (en el root se asocia a SSM).
    
- **`ami_ssm_parameter_name`**: parámetro SSM que contiene el AMI ID.
    
- **`user_data_path`**: ruta a script de user-data (base64 con `filebase64`).
    

### Health & listener

- **`frontend_port`**: puerto del servicio en la instancia (default 80).
    
- **`frontend_healthcheck_path`**: path del health check del target group (default `/`).
    

### Protección

- **`enable_deletion_protection`**: activa protección contra borrado del ALB.
    

### Tags

- **`tags`**: tags ya fusionadas en el root (common + role), se aplican a recursos del módulo y a instancias.
    

---

## 3) Qué hace el módulo (`modules/frontend/main.tf`)

### 3.1 Obtención de AMI desde SSM Parameter Store
```hcl
data "aws_ssm_parameter" "frontend_ami" {   name = var.ami_ssm_parameter_name }
```
- La AMI se obtiene **dinámicamente** por región.
    
- Ventaja: evita mantener un mapping manual de AMIs por región y permite “latest Amazon Linux 2” según SSM.
    

> Nota: el parámetro por defecto apunta a Amazon Linux 2 (`amzn2-ami-hvm-x86_64-gp2`).

### 3.2 Naming local (convención por rol)
```hcl
locals {   
	alb_name = "${var.role}-frontend-alb"   
	asg_name = "${var.role}-frontend-asg"   
	lt_name  = "${var.role}-frontend-lt"   
	... 
}
```


Esto garantiza nombres claros por región/rol.

### 3.3 `default_user_data_base64` (definido pero no usado)

El módulo define un `local.default_user_data_base64` que crea un HTTP server básico (Python), pero **en el estado actual del código no se usa**, porque el ASG toma el user-data con:
```hcl
user_data = filebase64(var.user_data_path)
```
Implicación:

- El comportamiento “por defecto” depende de que `user_data_path` apunte a un fichero existente (en este repo, `userdata/frontend/default.sh`).
    
- Si alguien pasa una ruta inválida, Terraform fallará al leer el fichero. y pasará a usar el defecto que ya trae el módulo.
    
---
## 4) ALB público (internet-facing) — `module "alb"`
```hcl
module "alb" {   
	source  = "terraform-aws-modules/alb/aws"   
	version = "10.5.0"    
	name               = local.alb_name   
	load_balancer_type = "application"   
	vpc_id             = var.vpc_id   
	subnets            = var.public_subnets   
	security_groups    = [var.alb_sg_id]   
	enable_deletion_protection = var.enable_deletion_protection   
	... 
}
```
### 4.1 Subredes y exposición pública

- `subnets = var.public_subnets` → el ALB queda en subredes públicas, por lo que es **accesible desde Internet**.
    
- El SG `alb_sg_id` debe permitir `80/443` desde `0.0.0.0/0` (lo hace el módulo network).
    

### 4.2 Listener HTTP
```hcl
listeners = {   
	http = {     
		port     = 80     
		protocol = "HTTP"     
		forward  = { target_group_key = "frontend" }   
	} 
}
```

- Expone **HTTP 80** y reenvía a un target group llamado `frontend`.
    
- No hay configuración de HTTPS/ACM en este módulo (se podría extender en el futuro).
    

### 4.3 Target Group `frontend`
```hcl
target_groups = {   
	frontend = {     
		protocol = "HTTP"     
		port     = var.frontend_port     
		target_type = "instance"     
		...     
		health_check = { path = var.frontend_healthcheck_path ... }   
	} 
}
```

Puntos clave:

- `target_type = "instance"`: el TG registra **instancias EC2** (no IPs).
    
- `create_attachment = false`: **no** se adjuntan targets manualmente aquí; el ASG se encargará de adjuntar el TG (ver `traffic_source_attachments`).
    
- Health checks:
    
    - `path = var.frontend_healthcheck_path` (default `/`)
        
    - `matcher = "200-399"`
        
    - thresholds y timings razonables (2/2, interval 30, timeout 5)
        

Esto es especialmente importante porque:

- Route 53 failover (en tu arquitectura) depende de la **salud del ALB primario**.
    
- La salud del ALB depende, a su vez, de la salud del target group (instancias frontend).
    

---

## 5) ASG Frontend — `module "asg"`
```hcl
module "asg" {   
	source  = "terraform-aws-modules/autoscaling/aws"   
	version = "9.1.0"    
	name                = local.asg_name   
	vpc_zone_identifier = var.private_subnets   
	... 
}
```
### 5.1 Ubicación de instancias (privadas)

- `vpc_zone_identifier = var.private_subnets`: las instancias se lanzan en **subredes privadas**.
    
- Esto evita exposición directa a Internet. Todo entra por el ALB público.
    

### 5.2 Capacidad (Pilot Light / Warm)

- `min_size`, `max_size`, `desired_capacity` vienen del root:
    
    - Primaria: valores >0 (servicio activo).
        
    - Secundaria: por defecto 0 (Pilot Light).
        

Efecto en DR:

- Con `desired=0`, el ALB secundario existirá, pero no tendrá targets sanos hasta que se escale el ASG.
    
- Route 53 podrá apuntar a la región secundaria, pero la recuperación dependerá de levantar instancias.
    

### 5.3 Health checks del ASG

`health_check_type         = "ELB" health_check_grace_period = 180`

- `ELB` indica que el ASG usa la salud reportada por el ALB/target group.
    
- `grace_period = 180` da tiempo a la instancia a bootstrapping antes de marcarla unhealthy.
    

### 5.4 Asociación ASG ↔ Target Group (ALB)
```hcl
traffic_source_attachments = {   
	frontend = {     
		traffic_source_identifier = module.alb.target_groups["frontend"].arn
		traffic_source_type       = "elbv2"   
	} 
}
```

Esto es clave: el ASG queda “conectado” al ALB y registra/deregistra instancias automáticamente en el TG.

### 5.5 Launch Template (implícito via módulo autoscaling)
```hcl
launch_template_name        = local.lt_name 
launch_template_description = "Frontend LT"  
image_id      = data.aws_ssm_parameter.frontend_ami.value 
instance_type = var.frontend_instance_type  
iam_instance_profile_name = var.iam_instance_profile_name 
security_groups           = [var.instance_sg_id]  
user_data = filebase64(var.user_data_path)
```


Con esto:

- AMI dinámica desde SSM.
    
- SG de instancias controlado por `network`.
    
- IAM instance profile (normalmente con SSM permissions).
    
- User-data desde fichero (default.sh monta un `python3 -m http.server`).
    

### 5.6 Tags en instancias
```hcl
tags = merge(var.tags, {   Name = "${var.name_prefix}-${var.role}-frontend-instance"   Tier = "Frontend" })
```


- Añade tags consistentes y un `Name` legible para inventario/cost allocation.
    

---

## 6) Outputs del módulo (`modules/frontend/outputs.tf`)

- **`alb_dns_name`**: DNS del ALB público regional (útil para pruebas directas).
    
- **`alb_arn`**: ARN del ALB (lo consume Route 53 en el root para `data "aws_lb"`).
    
- **`frontend_target_group_arn`**: ARN del TG (principalmente para depuración).
    
- **`asg_name`**: nombre del ASG (útil para operaciones y para escalar en DR manualmente).
    

---

## 7) Invocación del módulo frontend en el root (`main.tf`)

Se invoca dos veces: `frontend_primary` y `frontend_secondary`.

### 7.1 `module "frontend_primary"`

Aspectos clave:

#### Provider: 
```hcl
providers = { aws = aws.primary }
```
Garantiza despliegue en región primaria.
#### Dependencias de red (outputs del módulo `network_primary`):
```hcl
vpc_id          = module.network_primary.vpc_id 
public_subnets  = module.network_primary.public_subnets 
private_subnets = module.network_primary.private_subnets  
alb_sg_id      = module.network_primary.alb_frontend_sg_id 
instance_sg_id = module.network_primary.frontend_sg_id
```
#### Capacidad activa en primaria:
```hcl
min_size         = var.frontend_min_size_primary 
desired_capacity = var.frontend_desired_capacity_primary
```
#### Config de servicio:
```hcl
frontend_port             = var.frontend_port
frontend_healthcheck_path = var.frontend_healthcheck_path
frontend_instance_type    = var.frontend_instance_type
```
#### IAM Profile:
```hcl
iam_instance_profile_name = aws_iam_instance_profile.ec2_frontend_profile.name
```
(creado en root y con SSM Managed policy adjunta al rol)
#### AMI y user-data:
```hcl
ami_ssm_parameter_name = var.frontend_ami_ssm_parameter_name 
user_data_path         = var.frontend_user_data_path
```
#### Protección:
```hcl
enable_deletion_protection = var.enable_deletion_protection
```
- Tags:
```hcl
tags = merge(local.common_tags, local.primary_tags)
```
### 7.2 `module "frontend_secondary"`

Misma estructura, pero:

- Provider `aws.secondary`
    
- Consume outputs `module.network_secondary.*`
    
- Capacidad por defecto “Pilot Light”:
    
    `min_size         = var.frontend_min_size_secondary   # 0 desired_capacity = var.frontend_desired_capacity_secondary # 0`
    
- Tags con `local.secondary_tags`
    

---

## 8) Puntos finos / implicaciones operativas

1. **Relación salud ALB ↔ failover DNS**  
    El ALB primario se considera “sano” en Route 53 si su target group tiene targets sanos. Si el ASG pierde instancias o no responde el health check, Route 53 puede conmutar.
    
2. **Pilot Light en secundaria**  
    Con `desired=0` no hay targets → en un failover real se debe subir capacidad (manual o por automatización con ASG como es el caso de este lab). 
    
3. **HTTP-only** 
    Actualmente el listener es HTTP:80. Para entorno real, lo normal es:
    
    - ACM + HTTPS listener
        
    - redirección 80→443
        
    - WAF (opcional)