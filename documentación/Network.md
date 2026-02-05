## 1) Propósito del módulo `modules/network`

El módulo `network` es la **capa fundacional** de la infraestructura en **cada región**. Sus responsabilidades principales son:

1. **Crear la VPC y su segmentación** (subredes públicas, privadas de aplicación y privadas de base de datos).
    
2. Habilitar **salida a Internet controlada** para workloads en subredes privadas mediante **NAT Gateways**.
    
3. Configurar **observabilidad de red** mediante **VPC Flow Logs** almacenados en **S3**.
    
4. Endurecer el acceso a instancias privadas habilitando **AWS Systems Manager (SSM)** de forma privada mediante **VPC Interface Endpoints**.
    
5. Definir los **Security Groups** y reglas que implementan el **modelo 3-tier**:
    
    - Internet → ALB público → Frontend → ALB interno → Backend → RDS
        
    - Instancias → SSM Endpoints
        
    - Instancias → DNS Resolver de la VPC
        

> Resultado: el módulo expone outputs que permiten a los módulos `frontend`, `backend` y `database` consumir **IDs de VPC/subredes** y **SGs** ya predefinidos.

---

## 2) Entradas del módulo (`modules/network/variables.tf`)

### Identidad y naming
- **`name_prefix`**: prefijo general (en este caso se usa `terraform.workspace`).
    
- **`role`**: `"primary"` o `"secondary"`. Se usa para **nombres** y diferenciar recursos entre regiones.
    

### Red (topología)

- **`vpc_cidr`**: CIDR de la VPC.
    
- **`azs`**: lista de AZs a usar (por ejemplo 2 AZs).
    
- **`public_subnets`**: CIDRs de subredes públicas (1 por AZ).
    
- **`private_subnets`**: CIDRs de subredes privadas de aplicación (1 por AZ).
    
- **`database_subnets`**: CIDRs de subredes privadas de base de datos (1 por AZ).
    

### NAT (egreso controlado desde privadas)

- **`enable_nat_gateway`**: habilita NAT (default `true`).
    
- **`one_nat_gateway_per_az`**: un NAT por AZ (default `true`).
    
- **`single_nat_gateway`**: un único NAT para toda la VPC (default `false`).
    

> NAT habilitado + **uno por AZ**. Esto mejora resiliencia (evita SPOF) pero aumenta coste.

### Flow Logs (observabilidad)

- **`flow_logs_traffic_type`**: `ALL | ACCEPT | REJECT` (default `ALL`).
    
- **`flow_logs_s3_prefix`**: prefijo dentro del bucket S3 (default `vpc_flow-logs/`).
    
- **`flow_logs_force_destroy`**: permite borrar el bucket con objetos (default `true`) — solo usar para labs, en producción cambiar a false.
    

### VPC Endpoints SSM (gestión sin SSH)

- **`ssm_vpce_services`**: set con servicios SSM a crear como endpoints (`ssm`, `ec2messages`, `ssmmessages`).
    

### Tags

- **`tags`** + `public_subnet_tags` + `private_subnet_tags` + `database_subnet_tags`: se aplican a recursos VPC/subredes para organización y coste.
    

### Puertos “de contrato” con la capa app

- **`frontend_port`**: puerto del frontend (default `80`).
    
- **`backend_port`**: puerto del backend (default `8080`).
    

> Estos dos parámetros **solo** se usan en `security.tf` para crear reglas SG coherentes con los módulos `frontend` y `backend`.

---

## 3) Qué crea el módulo (`modules/network/main.tf`)

### 3.1 Datasources
```hcl
data "aws_caller_identity" "current" {} data "aws_region" "current" {}
```

- `aws_caller_identity`: se usa para construir una bucket policy segura para Flow Logs (limitando por cuenta y ARN).
    
- `aws_region`: se usa para:
    
    - nombre globalmente único del bucket (incluye región)
        
    - service_name de los VPC endpoints (depende de región)
        

### 3.2 Naming interno
```hcl
locals { name = "${var.name_prefix}-${var.role}" }
```
Ejemplo: `dev-primary` / `dev-secondary`.

### 3.3 Creación de la VPC (módulo oficial)
```hcl
module "vpc" {   source  = "terraform-aws-modules/vpc/aws"   version = "6.6.0"   ... }
```
Este módulo crea, entre otros:

- **VPC**
    
- **Subredes públicas** y **rutas** asociadas (incluye IGW)
    
- **Subredes privadas** y **rutas** asociadas (salida vía NAT)
    
- **Subredes de base de datos**
    
- **NAT Gateways** y EIPs (según flags)
    
- **Database subnet group** (porque `create_database_subnet_group = true`)
    

Detalles relevantes:

- `enable_dns_support = true` y `enable_dns_hostnames = true`: necesario para:
    
    - resolución DNS dentro de la VPC
        
    - nombres DNS de recursos internos
        
    - endpoints privados
        
- NAT:
    
    - Con `one_nat_gateway_per_az = true`, típicamente tendrás **N NATs** (N = número de AZs).
        
    - Esto evita que una caída de AZ deje sin salida a todas las subredes privadas.
        

### 3.4 Bucket S3 para Flow Logs

Se crea un bucket usando el módulo:
```hcl
module "s3_bucket_flow_logs" {   
	source  = "terraform-aws-modules/s3-bucket/aws"   
	version = "5.10.0"   
	bucket  = "${var.name_prefix}-vpc-${var.role}-flow-logs-${data.aws_region.current.region}"   
... 
}
```

Características de seguridad:

- Bloqueo de acceso público (ACLs y policy)
    
- `BucketOwnerEnforced` (evita ACLs tradicionales)
    
- Cifrado SSE-S3 (`AES256`)
    

> El nombre incluye `role` + `region` para minimizar colisiones (los nombres S3 son globales).

### 3.5 Bucket policy específica para VPC Flow Logs
```hcl
resource "aws_s3_bucket_policy" "flow_logs" { ... }
```
La policy permite al servicio `vpc-flow-logs.amazonaws.com`:

- `s3:PutObject` en el prefijo configurado
    
- `s3:GetBucketAcl`
    

Y restringe el write:

- por **cuenta** (`aws:SourceAccount`)
    
- por **ARN de origen** `arn:aws:ec2:<region>:<account>:vpc-flow-log/*`
    

> Este control evita que otras cuentas o fuentes no esperadas escriban en el bucket.

### 3.6 VPC Flow Logs hacia S3
```hcl
resource "aws_flow_log" "vpc" {   
	vpc_id = module.vpc.vpc_id   
	traffic_type = var.flow_logs_traffic_type   
	log_destination_type = "s3"   
	log_destination = "${bucket_arn}/${prefix}"   
	max_aggregation_interval = 600 
}
```
- `max_aggregation_interval = 600`: agrega logs cada 10 minutos (reduce volumen/requests).
    
- `depends_on` con la bucket policy: asegura orden correcto (primero permisos, luego flow logs).
    

### 3.7 VPC Interface Endpoints para SSM
```hcl
resource "aws_vpc_endpoint" "ssm" {   
	for_each = var.ssm_vpce_services   
	vpc_endpoint_type = "Interface"   
	subnet_ids = module.vpc.private_subnets   
	security_group_ids = [aws_security_group.vpce_sg.id]   
	private_dns_enabled = true 
}
```


- Crea endpoints en **subredes privadas**.
    
- Asocia un SG dedicado (`vpce_sg`) para controlar quién puede llegar al endpoint.
    
- `private_dns_enabled = true`: permite que los nombres estándar de AWS resuelvan a IPs privadas dentro de la VPC.
    

**Efecto práctico:** instancias en privadas pueden ser gestionadas vía SSM **sin necesidad** de:

- IP pública
    
- bastion
    
- abrir SSH
    
- salir a Internet para llegar a endpoints públicos
    

---

## 4) Seguridad del módulo (`modules/network/security.tf`)

Este archivo define **Security Groups** y **reglas** que implementan el **modelo de comunicación** 3-tier + endpoints + DNS.

### 4.1 Local: resolver CIDR
```hcl
locals {   vpc_resolver_cidr = "${cidrhost(module.vpc.vpc_cidr_block, 2)}/32" }
```
- En AWS, el **DNS resolver** dentro de la VPC es típicamente la IP `base+2` del CIDR (ej: `10.10.0.2`).
    
- Este local se usa para permitir egress DNS **solo** hacia el resolver (en vez de abrir DNS a todo).
    

### 4.2 Local: mapa de SGs de instancias
```hcl
locals {   
	app_instance_sg = {     
		frontend = aws_security_group.frontend_sg.id     
		backend  = aws_security_group.backend_sg.id   
	} 
}
```
Se usa para aplicar reglas repetidas (SSM/DNS/HTTPS) de forma consistente a frontend y backend con `for_each`.

### 4.3 Security Groups creados

1. **`alb_frontend_sg`** (ALB público)
    

- Entrada desde Internet (80/443).
    
- Salida únicamente hacia SG del frontend en `frontend_port`.
    

2. **`frontend_sg`** (instancias frontend)
    

- Entrada únicamente desde SG del ALB público en `frontend_port`.
    
- Salida hacia SG del ALB interno en `backend_port`.
    
- Salida a VPCE SSM (443).
    
- Salida DNS al resolver (53 udp/tcp).
    
- Salida HTTPS a Internet (443) — normalmente a través de NAT.
    

3. **`alb_backend_sg`** (ALB interno)
    

- Entrada desde frontend en `backend_port`.
    
- Salida hacia backend en `backend_port`.
    

4. **`backend_sg`** (instancias backend)
    

- Entrada solo desde SG del ALB interno en `backend_port`.
    
- Salida hacia DB en `5432`.
    
- Salida a VPCE SSM (443).
    
- Salida DNS al resolver (53 udp/tcp).
    
- Salida HTTPS a Internet (443) — via NAT.
    

5. **`db_sg`** (RDS)
    

- Entrada solo desde backend en `5432`.
    

6. **`vpce_sg`** (Interface endpoints SSM)
    

- Entrada en `443` desde frontend y backend.
    
- No expone el endpoint al resto del mundo; solo a los SGs de app.
    

### 4.4 Reglas clave (resumen por flujo)

**Internet → ALB público**

- Ingress 80/443 desde `0.0.0.0/0` al SG del ALB público.
    

**ALB público → Frontend**

- Egress del ALB público a `frontend_sg` en `frontend_port`
    
- Ingress del frontend desde `alb_frontend_sg` en `frontend_port`
    

**Frontend → ALB interno**

- Egress del frontend a `alb_backend_sg` en `backend_port`
    
- Ingress del ALB interno desde `frontend_sg` en `backend_port`
    

**ALB interno → Backend**

- Egress del ALB interno a `backend_sg` en `backend_port`
    
- Ingress del backend desde `alb_backend_sg` en `backend_port`
    

**Backend → DB**

- Egress del backend hacia `db_sg` en `5432`
    
- Ingress en DB desde `backend_sg` en `5432`
    

**Frontend/Backend → SSM VPCE (443)**

- Reglas generadas con `for_each` para ambos SGs.
    

**Frontend/Backend → DNS resolver (53 udp/tcp)**

- Reglas generadas con `for_each` hacia `vpc_resolver_cidr`.
    

**Frontend/Backend → HTTPS a Internet (443)**

- Egress 443 a `0.0.0.0/0` (el camino real será vía NAT por rutas).
    

> Importante: el módulo no crea NACLs específicas; el control se centra en SGs (stateful) + segmentación por subred.

---

## 5) Outputs del módulo (`modules/network/outputs.tf`) y por qué son críticos

El módulo expone:

- Identidad de red:
    
    - `vpc_id`, `vpc_cidr_block`
        
    - `public_subnets`, `private_subnets`, `database_subnets`
        
- Observabilidad:
    
    - `flow_logs_s3_destination_arn`
        
- Seguridad (IDs de SG listos para consumir):
    
    - `alb_frontend_sg_id`
        
    - `frontend_sg_id`
        
    - `alb_backend_sg_id`
        
    - `backend_sg_id`
        
    - `db_sg_id`
        
    - `vpce_sg_id`
        
    - `app_instance_sg_ids` (map frontend/backend)
        

Estos outputs son la **interfaz** entre el módulo network y el resto del stack:

- `frontend` necesita `vpc_id`, subredes y SGs del ALB + instancias.
    
- `backend` necesita `vpc_id`, subredes privadas y SGs del ALB interno + instancias.
    
- `database` necesita `database_subnets` y `db_sg_id`.
    

---

## 6) Invocación del módulo network desde el root (`main.tf`)

En el root se instancia el módulo **dos veces**: una por región.

### 6.1 Selección dinámica de AZs por región (root)
```hcl
data "aws_availability_zones" "primary" { 
	state = "available" 
} 

data "aws_availability_zones" "secondary" { 
	provider = aws.secondary 
... 
}  

locals {   
	azs_primary   = slice(sort(data.aws_availability_zones.primary.names), 0, var.az_count)   
	azs_secondary = slice(sort(data.aws_availability_zones.secondary.names), 0, var.az_count) 
}
```


- Esto asegura que el despliegue es “portable”: no hardcodea nombres de AZ.
    
- `var.az_count` controla cuántas AZs se usan (normalmente 2).
    

### 6.2 Estructura `locals.network` (root)

El root construye un objeto `local.network` con dos ramas (`primary` y `secondary`) que agrupan:

- role
    
- azs
    
- cidr
    
- subnets
    
- tags por tier
    

Esto:

- reduce duplicación
    
- estandariza naming y tags
    
- hace más fácil “clonar” el patrón a nuevas regiones
    

### 6.3 Common config compartida (root)
```hcl
locals {   
	vpc_common = {     
		enable_nat_gateway     = true     
		one_nat_gateway_per_az = true     
		single_nat_gateway     = false     
		flow_logs_traffic_type = var.flow_logs_traffic_type     
		flow_logs_s3_prefix    = var.flow_logs_s3_prefix     
		ssm_vpce_services      = toset(["ssm", "ec2messages", "ssmmessages"])   
	} 
}
```


Esto define defaults consistentes para ambas regiones (especialmente útil en DR para mantener paridad).

### 6.4 `module "network_primary"`

Puntos clave:

- `providers = { aws = aws.primary }`  
    Fuerza a que **todo** lo creado por esa instancia del módulo ocurra en la región primaria.
    
- Pasa `name_prefix = terraform.workspace`  
    Naming por entorno (`dev`, `prod`, etc.).
    
- Pasa los parámetros de topología: `azs`, `vpc_cidr`, `public/private/database subnets`.
    
- Pasa `frontend_port` y `backend_port` para que las reglas SG encajen con los módulos app.
    

### 6.5 `module "network_secondary"`

Idéntico patrón, pero:

- `providers = { aws = aws.secondary }`
    
- `role = "secondary"`
    
- usa `azs_secondary` y CIDRs/subnets de la región secundaria
    

**Resultado**: dos VPCs independientes (una por región), cada una con:

- subredes por tier
    
- NAT por AZ
    
- Flow logs en S3 (bucket regional distinto)
    
- endpoints SSM
    
- SGs consistentes para todo el stack
    

---

## 7) Cómo el resto del stack depende del módulo network (solo a nivel interfaz)

- `frontend_*` consume:
    
    - `module.network_*.vpc_id`
        
    - `module.network_*.public_subnets` (ALB público)
        
    - `module.network_*.private_subnets` (ASG)
        
    - `module.network_*.alb_frontend_sg_id`
        
    - `module.network_*.frontend_sg_id`
        
- `backend_*` consume:
    
    - `module.network_*.vpc_id`
        
    - `module.network_*.private_subnets` (ALB interno + ASG)
        
    - `module.network_*.alb_backend_sg_id`
        
    - `module.network_*.backend_sg_id`
        
- `database` consume:
    
    - `module.network_*.database_subnets`
        
    - `module.network_*.db_sg_id`
        

Esto confirma que el módulo network actúa como **“source of truth”** de:

- segmentación
    
- conectividad permitida
    
- outputs reutilizables
    

---

## 8) Notas técnicas / consideraciones

- **DNS Resolver restrictivo:** permitir 53 solo a `x.x.x.2/32` es una buena práctica para no abrir DNS indiscriminadamente.
    
- **SSM private by design:** endpoints en privadas + SG dedicado hacen que el control de gestión no dependa de Internet.
    
- **Flow Logs a S3 con policy restringida:** reduce superficie de riesgo en logging.
    
- **NAT por AZ:** alta disponibilidad de egress.
    
- **Tags por tier y rol:** facilitan análisis de costes y gobierno (cost allocation / inventory).