## 1) Propósito del módulo `modules/database`

El módulo `database` encapsula la creación de una instancia **Amazon RDS PostgreSQL** en **una región** en dos modos:

- **Modo Primary (writer)**: crea un RDS “normal” (`aws_db_instance.primary`) con parámetros típicos de producción (Multi-AZ, backups, cifrado, etc.).
    
- **Modo Replica (read replica cross-region)**: crea un RDS como **read replica** (`aws_db_instance.replica`) apuntando a un `replicate_source_db` (ARN del primario).
    

Este diseño permite que el root:

- Cree **un writer Multi-AZ** en la región primaria.
    
- Cree **una réplica cross-region** en la región secundaria.
    
- Mantenga un **hostname estable** para la aplicación mediante **Route 53 Private Hosted Zone**.
    

---

## 2) Entradas del módulo (`modules/database/variables.tf`)

### Identidad / naming

- **`name_prefix`**: prefijo común (en root: `terraform.workspace`).
    
- **`role`**: `"primary"` o `"secondary"`. Se usa en nombres/identificadores.
    

### Red / seguridad

- **`db_subnets`**: subredes de base de datos (privadas) para crear el `aws_db_subnet_group`.
    
- **`vpc_security_group_ids`**: SG(s) aplicados al RDS. En esta arquitectura se pasa el **SG de DB** del módulo `network` (que solo permite 5432 desde backend).
    

### Parámetros del motor / almacenamiento

- **`instance_class`**: clase de instancia (`db.t3.micro`, etc).
    
- **`engine_version`**: versión de PostgreSQL (puede ser `null` para default regional).
    
- **`allocated_storage`**: tamaño de almacenamiento **solo relevante en primario** (en réplicas se fuerza a `null`).
    
- **`storage_type`**: tipo de volumen (default `gp3`).
    

### Parámetros de base de datos

- **`db_name`**, **`username`**, **`password`**:
    
    - `password` es `sensitive` y opcional.
        
    - Validación: si se define, mínimo 12 caracteres.
        

### Disponibilidad / backups

- **`multi_az`**: default `true` (en root lo activas solo para primaria).
    
- **`backup_retention_period`**: días de retención (en réplica se fuerza a 0 por diseño del módulo).
    
- **`deletion_protection`**: proteger contra borrado accidental.
    
- **`apply_immediately`**: aplicar cambios sin ventana de mantenimiento.
    

### Snapshots

- **`skip_final_snapshot`** y **`final_snapshot_identifier`**:
    
    - Si `skip_final_snapshot=false`, el módulo crea un nombre final (si no se proporciona) con `coalesce`.
        

### Cifrado

- **`kms_key_id`**: KMS key ARN/ID para cifrar almacenamiento.
    

### Modo réplica

- **`is_replica`**: booleano que decide qué recurso se crea.
    
- **`replicate_source_db`**: ARN del primario para cross-region replica.
    

### Tags

- **`tags`**: tags a aplicar.
    

---

## 3) Implementación interna (`modules/database/main.tf`)

### 3.1 Naming interno y snapshot final
```hcl
locals {   
	identifier        = "${var.name_prefix}-rds-${var.role}"   
	subnet_group_name = "${var.name_prefix}-rds-${var.role}-subnets"    
	final_snapshot_id = coalesce(     
		var.final_snapshot_identifier,     
		"${local.identifier}-final"   
	) 
}
```
- `identifier` produce nombres como `dev-rds-primary` / `dev-rds-secondary`.
    
- `final_snapshot_id` se usa solo si `skip_final_snapshot=false`.
    

---

### 3.2 Subnet group de RDS
```hcl
resource "aws_db_subnet_group" "this" {   
	name       = local.subnet_group_name   
	subnet_ids = var.db_subnets   
	... 
}
```
- AWS RDS requiere un `DB Subnet Group` para ubicar la instancia en subredes privadas.
    
- Etiquetado incluye `Tier="Database"`.
    

---

### 3.3 Recurso Primary (writer) — `aws_db_instance.primary`
```hcl
resource "aws_db_instance" "primary" {   
	count = var.is_replica ? 0 : 1   ... }
```
Se crea **solo si** `is_replica=false`.

Características clave:

- **PostgreSQL**
    
    - `engine = "postgres"`
        
    - `engine_version = var.engine_version`
        
- **Red**
    
    - `db_subnet_group_name = aws_db_subnet_group.this.name`
        
    - `vpc_security_group_ids = var.vpc_security_group_ids`
        
    - `publicly_accessible = false` (solo privado)
        
- **Alta disponibilidad**
    
    - `multi_az = var.multi_az` (en root lo pones `true` para primaria)
        
- **Cifrado**
    
    - `storage_encrypted = true`
        
    - `kms_key_id = var.kms_key_id`
        
- **Credenciales**
    
    - `db_name`, `username`, `password` (en root usas `random_password`)
        
- **Backups y mantenimiento**
    
    - `backup_retention_period = var.backup_retention_period`
        
    - `auto_minor_version_upgrade = true`
        
- **Snapshots**
    
    - `skip_final_snapshot` y `final_snapshot_identifier` según variables
        

---

### 3.4 Recurso Replica (cross-region) — `aws_db_instance.replica`
```hcl
resource "aws_db_instance" "replica" {   
	count = var.is_replica ? 1 : 0   
	replicate_source_db = var.replicate_source_db   
	... 
}
```
Se crea **solo si** `is_replica=true`.

Diferencias y detalles importantes:

- **No define almacenamiento inicial**
    
    `allocated_storage = null`
    
    En read replicas lo normal es heredar/gestionar de forma distinta.
    
- **Replica cross-region**
    
    `replicate_source_db = var.replicate_source_db`
    
- **Backups desactivados en réplica**
    
    `backup_retention_period = 0`
    
    Esto reduce coste y evita duplicar backups en la réplica (además es habitual en DR).
    
- **Lifecycle ignore en `replicate_source_db`**
    
    `lifecycle {   ignore_changes = [replicate_source_db] }`
    
    Esto es crucial por DR manual:
    
    - Si **promueves** la réplica a writer, AWS elimina el vínculo `replicate_source_db`.
        
    - Sin `ignore_changes`, Terraform intentaría “reconectar” la réplica al primario, causando drift y potenciales problemas.
        

---

## 4) Outputs del módulo (`modules/database/outputs.tf`)

Estos outputs abstraen si es primary o replica:

- **`db_instance_id`**: ID de la instancia creada.
    
- **`db_instance_arn`**: ARN (especialmente importante: se usa para `replicate_source_db`).
    
- **`db_address`**: hostname base.
    
- **`db_endpoint`**: endpoint completo `host:port` que expone AWS.
    
- **`db_port`**: puerto.
    

---

## 5) Orquestación en el root (`rds.tf`)

Aquí es donde realmente se construye la estrategia DR:

### 5.1 Password aleatorio + KMS por región

- `random_password.db_master` genera la contraseña
    
- `aws_kms_key.rds_primary` y `aws_kms_key.rds_secondary`:
    
    - Una KMS key por región para cifrado de RDS y Secrets.
        
    - Rotación activada (`enable_key_rotation=true`).
        

---

### 5.2 Secret en Secrets Manager replicado cross-region
```hcl
resource "aws_secretsmanager_secret" "db" {   
	provider = aws.primary   
	...   
	replica {     
		region     = var.secondary_region     
		kms_key_id = aws_kms_key.rds_secondary.arn   
	} 
}
```
- Se crea **en primaria** y se replica automáticamente a secundaria.
    
- El secret contiene:
    
    - `username`, `password`, `dbname`, `port`
        
    - y muy importante: `host = db.pilotlight.internal` (hostname estable)
        

**Objetivo:** la aplicación no debe depender de endpoints regionales cambiantes; debe usar un host estable.

---

### 5.3 Invocación del módulo: DB primaria (writer Multi-AZ)
```hcl
module "db_primary" {   
	providers = { 
		aws = aws.primary 
	}    
	db_subnets             = module.network_primary.database_subnets   
	vpc_security_group_ids = [module.network_primary.db_sg_id]    
	engine_version    = var.db_engine_version   
	instance_class    = var.db_instance_class_primary   
	allocated_storage = var.db_allocated_storage    
	db_name  = var.db_name   
	username = var.db_username   
	password = random_password.db_master.result   
	port     = var.db_port    
	multi_az                = true   
	backup_retention_period = var.db_backup_retention_days   
	deletion_protection     = var.db_deletion_protection    
	kms_key_id = aws_kms_key.rds_primary.arn   
	is_replica = false 
}
```
Puntos clave:

- Subredes DB y SG DB provienen de `network_primary`.
    
- Multi-AZ `true` solo aquí.
    
- Backups configurables.
    

---

### 5.4 Invocación del módulo: DB secundaria (read replica cross-region)
```hcl
module "db_secondary" {   
	providers = { 
		aws = aws.secondary 
	}    
	db_subnets             = module.network_secondary.database_subnets   
	vpc_security_group_ids = [module.network_secondary.db_sg_id]    
	is_replica          = true   
	replicate_source_db = module.db_primary.db_instance_arn    
	multi_az            = false   
	kms_key_id          = aws_kms_key.rds_secondary.arn 
}
```
Puntos clave:

- Es **read replica** y cuelga del primario por ARN.
    
- Multi-AZ desactivado por coste.
    
- Mantiene cifrado con KMS de secundaria.
    

---

## 6) DNS privado estable (Route 53 Private Hosted Zone)

### 6.1 Zona privada creada en primaria y asociada a ambas VPCs
```hcl
resource "aws_route53_zone" "db_private" {   
	provider = aws.primary   
	name = var.db_private_zone_name   
	vpc { 
		vpc_id = module.network_primary.vpc_id 
	} 
} 

resource "aws_route53_zone_association" "db_private_secondary" {   
	provider   = aws.secondary   
	zone_id    = aws_route53_zone.db_private.zone_id   
	vpc_id     = module.network_secondary.vpc_id   
	vpc_region = var.secondary_region 
}
```
Efecto:

- Desde **ambas VPCs** (primaria y secundaria) se puede resolver:
    
    - `db.pilotlight.internal` (o el dominio que configures)
        

### 6.2 Record writer estable
```hcl
resource "aws_route53_record" "db_writer" {   
	name    = "${var.db_record_name}.${var.db_private_zone_name}"   
	type    = "CNAME"   
	ttl     = 30   
	records = [module.db_primary.db_address] 
}
```

- Por defecto apunta al **writer primario**.
    
- En una posible automatización, este record sería el “switch” para apuntar al writer activo tras promoción en DR.

---

## 7) DR de base de datos: por qué es manual en este proyecto

La arquitectura **sí** automatiza failover de **tráfico** (Route 53 a ALB secundario), pero el **writer de RDS** no cambia automáticamente porque:

- Se está usando **RDS PostgreSQL** con **read replica** cross-region (no Aurora global).
    
- La promoción de réplica, recreación del primario y reenganche de réplica implica varios pasos y es un buen candidato a automatización (Lambda/Step Functions), pero está fuera de scope/tiempo y el free-tier de la cuenta aws que se está usando para este lab.
    

Por eso:

- El sistema **notifica** a responsables (SNS Email).
    
- Los responsables ejecutan el **runbook manual** para:
    
    1. Promover la réplica secundaria a writer.
        
    2. Actualizar el DNS estable (`db.pilotlight.internal`) para que apunte al writer.
        
    3. Tras recuperar primaria, recrear el writer en primaria a partir de snapshot y restablecer la réplica cross-region.
        
    4. Limpiar recursos obsoletos.
        

---

## 8) Notificaciones DR (SNS + CloudWatch Alarm) — soporte al runbook manual

sns.tf implementa un sistema de notificación desacoplado:

1. **Route 53 HealthCheck** detecta caída del ALB primario.
    
2. **CloudWatch Alarm** monitoriza `AWS/Route53 - HealthCheckStatus`.
    
3. Alarmas publican en **SNS Topics**:
    
    - `dr_failover` cuando pasa a ALARM (primario unhealthy)
        
    - `dr_failback` cuando vuelve a OK
        
4. **SNS Email subscriptions** notifican a la lista `dr_notification_emails`.
    

Notas relevantes:

- El alarm debe vivir en **us-east-1** (en el código se resuelve usando un provider dedicado `aws.sns`).
    
- Esto no ejecuta acciones automáticas sobre RDS: solo envia notificaciones a los responsables de realizar las acciones del **runbook**.
    

---

## 9) Implicaciones técnicas

1. **`ignore_changes = [replicate_source_db]` es clave para DR real**  
    Evita que Terraform intente “despromover” o re-colgar una réplica tras una promoción manual.
    
2. **DNS estable = desacoplar aplicación de endpoints**  
    El secret guarda como host `db.pilotlight.internal`, lo que permite cambiar el writer sin tocar config de app (solo cambiando el CNAME).
    
3. **Backups en réplica = 0**  
    Reduce coste y evita redundancias. El primario conserva backups.
    
4. **Cifrado end-to-end**  
    RDS cifrado con KMS por región + secret cifrado con KMS y replicado.