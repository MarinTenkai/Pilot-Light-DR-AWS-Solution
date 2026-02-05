## 1) Objetivo de `route53.tf` (DNS público con failover Pilot Light)

El fichero `route53.tf` implementa el **punto de entrada público** del sistema usando **Route 53 Failover Routing**:

- Se crea una **Hosted Zone pública** (demo con `pilotlight.invalid` o real con un dominio en propiedad).
    
- Se crean **dos registros A (Alias)** con la **misma FQDN**:
    
    - **PRIMARY** → ALB público del **frontend en la región primaria**.
        
    - **SECONDARY** → ALB público del **frontend en la región secundaria**.
        
- Un **Health Check de Route 53** monitoriza el ALB primario.
    
- Si el health check marca el primario como **unhealthy**, Route 53 responde con el record **SECONDARY**.
    

Esto resuelve el failover “a nivel DNS” típico de una estrategia **Pilot Light**.

---

## 2) Variables específicas de Route 53 (definidas en `route53.tf`)

> Estas variables son propias de Route 53 (aunque conviven con el resto de variables del root).

### Hosted Zone / Nombre público

- **`route53_zone_name`** (default `pilotlight.invalid`)
    
    - Nombre de la **Hosted Zone pública**.
        
    - Importante: puedes crear la zona sin comprar dominio, pero **si no hay delegación real** (NS en tu registrar), el nombre **no será resoluble desde Internet**.
        
- **`route53_record_name`** (default `app`)
    
    - Subdominio para el entrypoint público.
        
    - El FQDN final será:  
        **`${route53_record_name}.${route53_zone_name}`** → por defecto `app.pilotlight.invalid`.
        

### Health check

- **`route53_health_check_type`**: `HTTP` o `HTTPS`.
    
- **`route53_health_check_port`**: por defecto `80`.
    
- **`route53_health_check_path`**: por defecto `/`.
    
- **`route53_health_check_request_interval`**: 10 o 30s (default 30).
    
- **`route53_health_check_failure_threshold`**: nº fallos consecutivos antes de unhealthy (default 3).
    

En la práctica, con defaults **30s × 3** → el failover suele activarse tras ~**90s** (más el efecto de cachés DNS de los resolvers).

### Alias evaluation

- **`route53_evaluate_target_health`** (default `true`)
    
    - En alias records, indica si Route 53 debe considerar el estado del target (ALB).
        
    - En el código **no se usa esta variable** directamente en ambos records: en primario se fuerza `true` y en secundario `false` (ver más abajo).
        

---

## 3) Dependencias con el módulo `frontend` (cómo se instegra Route 53 a los ALB)

Route 53 necesita **DNS name** y **Hosted Zone ID** del ALB para crear los Alias. Como los ALB los crea el módulo `frontend`, aquí se “descubren” con data sources:
```hcl
data "aws_lb" "frontend_primary" {   
	provider = aws.primary   
	arn      = module.frontend_primary.alb_arn 
}  

data "aws_lb" "frontend_secondary" {   
	provider = aws.secondary   
	arn      = module.frontend_secondary.alb_arn 
}
```
### Qué consigue esto

- **`module.frontend_*`** expone `alb_arn`.
    
- Con el `data "aws_lb"` obtienes:
    
    - `dns_name` del ALB (ej: `xxx.elb.amazonaws.com`)
        
    - `zone_id` del ALB (necesario para Alias)
        
- Se mantiene el acoplamiento “limpio”: Route 53 no depende de nombres hardcodeados, sino de outputs del módulo.
    

> Además, se usan providers distintos: el ALB primario se consulta en `aws.primary` y el secundario en `aws.secondary`.

---

## 4) Hosted Zone pública (`aws_route53_zone.public`)
```hcl
resource "aws_route53_zone" "public" {   
	provider = aws.primary   
	name    = var.route53_zone_name   
	comment = "Public Hosted Zone - ${var.project_name} (${terraform.workspace})"   
	... 
}
```
### Comportamiento real vs demo

- **Crear la zona**: siempre se puede.
    
- **Que el mundo resuelva el dominio**:
    
    - Solo ocurre si el dominio está **delegado** a los NS de Route 53 (registrar → NS que te da Route 53).
        
    - Con `.invalid` (TLD reservado) **normalmente no habrá delegación pública**, así que vale como entorno de pruebas, pero **no como entrada real** desde Internet.
        

---

## 5) Health Check del primario (`aws_route53_health_check.frontend_primary`)
```hcl
resource "aws_route53_health_check" "frontend_primary" {   
	type          = var.route53_health_check_type   
	fqdn          = data.aws_lb.frontend_primary.dns_name   
	port          = var.route53_health_check_port   
	resource_path = var.route53_health_check_path   
	request_interval  = var.route53_health_check_request_interval   
	failure_threshold = var.route53_health_check_failure_threshold 
}
```
### Qué está haciendo exactamente

- Route 53 ejecuta un health check **contra el DNS público del ALB primario**.
    
- Evalúa:
    
    - Protocolo (`HTTP` / `HTTPS`)
        
    - Puerto
        
    - Path
        
    - Intervalo y threshold
        

---

## 6) Failover record PRIMARY (`aws_route53_record.frontend_failover_primary`)
```hcl
resource "aws_route53_record" "frontend_failover_primary" {   
	name = "${var.route53_record_name}.${var.route53_zone_name}"   
	type = "A"   
	set_identifier = "${terraform.workspace}-primary"    
	failover_routing_policy { type = "PRIMARY" }    
	alias {     
		name                   = data.aws_lb.frontend_primary.dns_name     
		zone_id                = data.aws_lb.frontend_primary.zone_id     
		evaluate_target_health = true   
	}    
	health_check_id = aws_route53_health_check.frontend_primary.id    
	lifecycle { create_before_destroy = true } 
}
```
### Puntos clave

- **Mismo nombre** (`app.pilotlight.invalid`) que el secundario: Route 53 elegirá cuál responder según el estado.
    
- `set_identifier` es obligatorio en políticas de failover (distingue las dos entradas).
    
- `failover_routing_policy` con `PRIMARY`.
    

### Doble capa de validación de salud

- `health_check_id` fuerza que Route 53 considere el primario “unhealthy” si falla el check.
    
- `evaluate_target_health = true` hace que, además, Route 53 pueda considerar el “estado del target” (ALB) en resoluciones Alias.
    

En conjunto: el primario solo “gana” si el health check está OK (y el alias target health también ayuda como señal adicional).

---

## 7) Failover record SECONDARY (`aws_route53_record.frontend_failover_secondary`)
```hcl
resource "aws_route53_record" "frontend_failover_secondary" {   
	name = "${var.route53_record_name}.${var.route53_zone_name}"   
	type = "A"   
	set_identifier = "${terraform.workspace}-secondary"    
	failover_routing_policy { type = "SECONDARY" }    
	alias {     
		name                   = data.aws_lb.frontend_secondary.dns_name     
		zone_id                = data.aws_lb.frontend_secondary.zone_id     
		evaluate_target_health = false   
	}    
	lifecycle { create_before_destroy = true } 
}
```
### Por qué es relevante que aquí sea distinto

- No lleva `health_check_id`.
    
- `evaluate_target_health = false`.
    

**Interpretación:**

- En Pilot Light, la región secundaria puede estar “a medio gas” (por ejemplo, ASG con desired=0 o servicios sin levantar).
    
- Si Route 53 evaluase también la salud del secundario, podría ocurrir que:
    
    - primario cae,
        
    - secundario aún no está listo,
        
    - Route 53 se quede sin respuesta “saludable” o se comporte de forma no deseada.
        
- Con `evaluate_target_health=false`, Route 53 **responde el secundario cuando el primario cae**, y es la intervención manual o aumtomática del ASG quien asegura que la capacidad se levante rápidamente.
    

**Trade-off:** si el secundario aún no está listo, podrías dirigir tráfico a un endpoint que todavía no responde. Eso es una decisión consciente en Pilot Light: priorizas **conmutar** y luego **activar capacidad**.

---

## 8) Flujo de failover (lo que pasa cuando cae la región primaria)

1. El cliente resuelve `app.<zone>` y Route 53 responde el **PRIMARY**.
    
2. Route 53 ejecuta health checks periódicos contra el ALB primario.
    
3. Si el ALB primario falla el health check durante `failure_threshold` intervalos:
    
    - Route 53 marca el PRIMARY como **unhealthy**.
        
4. En resoluciones posteriores, Route 53 responde el **SECONDARY** (ALB secundario).
    

**Importante:** la velocidad percibida del cambio depende de:

- Intervalo/threshold del health check.
    
- Caché DNS del resolver del cliente.
    

---

## 9) Integración con las notificaciones DR (SNS / CloudWatch Alarm)

En tu proyecto, el `HealthCheckId` de Route 53 se usa también como señal operativa:

- El **CloudWatch Alarm** (en `sns.tf`) observa `AWS/Route53 - HealthCheckStatus`.
    
- Si pasa a unhealthy, dispara SNS email → inicia el runbook manual (por ejemplo para DB, o para escalado/acciones en secundario).
    

Es decir: Route 53 no solo enruta; también funciona como **sensor** de la salud del primario.

---

## 10) Consideraciones y extensiones típicas

- **Dominio real**: si quieres que sea accesible desde Internet, debes:
    
    - comprar/poseer dominio,
        
    - delegar NS al conjunto de nameservers de la hosted zone de Route 53.
        
- **HTTPS end-to-end**:
    
    - cambiar listener del ALB a 443 con ACM,
        
    - health check de Route 53 a `HTTPS` (o mantener HTTP si el ALB redirige).
        
- **Health check del secundario** (opcional):
    
    - si se cambias a Warm Standby con una capacidad mínima de computación siempre activa en la región secundaría, podría tener sentido evaluar target health también en secondary.