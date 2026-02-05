# Pilot Light Disaster Recovery (3-Tier) en AWS con Terraform (Multi-Region)

Implementación **multi-región** de una arquitectura **3-tiers** (Frontend / Backend / Database) en AWS siguiendo el patrón **Pilot Light Disaster Recovery**, desplegada con **Terraform** y pensada para usarse como proyecto **formativo** y **portfolio** (AWS Solutions Architect + Terraform Associate).

![[Pilot Light Disaster Recovery - AWS Solutions Architech.png]]
> Referencia oficial (AWS) del patrón Pilot Light DR:  
> https://docs.aws.amazon.com/whitepapers/latest/disaster-recovery-workloads-on-aws/disaster-recovery-options-in-the-cloud.html
## Objetivos del proyecto

- Practicar diseño de **arquitecturas resilientes** en AWS (multi-AZ + multi-region).
- Practicar IaC con **Terraform** usando un enfoque modular y reutilizable.
- Proveer un repositorio público que cualquier persona pueda clonar y desplegar rápidamente ajustando unas pocas variables.

---
## Arquitectura (alto nivel)

**Región primaria (producción)**: `eu-south-2` (España)  
**Región secundaria (DR)**: `eu-west-3` (París)

### Flujo de tráfico (3-tiers)

1. **Route 53 (Failover DNS)** expone un único FQDN público (por defecto `app.pilotlight.invalid`).
2. El tráfico entra por un **ALB público** en cada región:
   - **PRIMARY**: recibe tráfico normalmente.
   - **SECONDARY**: actúa como destino en caso de conmutación por error.
3. El ALB público enruta a un **Auto Scaling Group (ASG) de Frontend** en **subredes privadas**.
4. El Frontend consume el Backend mediante un **ALB interno (privado)**.
5. El ALB interno enruta a un **ASG de Backend** en **subredes privadas**.
6. El Backend accede a **RDS PostgreSQL**:
   - **Primaria**: **Multi-AZ** (writer).
   - **Secundaria**: **read replica cross-region**.

### Pilot Light vs Warm Standby (coste vs RTO)

En Pilot Light, la **región secundaria** mantiene la infraestructura “mínima” lista, pero **con capacidad de cómputo a 0**:

- `frontend_min_size_secondary = 0` / `frontend_desired_capacity_secondary = 0`
- `backend_min_size_secondary = 0` / `backend_desired_capacity_secondary = 0`

✅ **Ventaja**: menor coste.  
⚠️ **Desventaja**: aumenta el tiempo de recuperación (RTO), porque durante el failover el ASG debe lanzar instancias desde cero.

Si quieres evolucionarlo a **Warm Standby**, sube `min_size` y `desired_capacity` en secundaria (por ejemplo a 1 o 2) para que haya capacidad “caliente” disponible, a cambio de mayor coste.

---

## Conmutación por error (Route 53)

- Se crea una **Hosted Zone pública** y un **record A (Alias)** con política **Failover**:
  - **PRIMARY** → ALB público de la región primaria.
  - **SECONDARY** → ALB público de la región secundaria.
- **Route 53 Health Check** se realiza contra el **ALB público primario**.
- Si el health check se marca como **unhealthy**, Route 53 conmuta el DNS a **SECONDARY**. Además se envía una notificación por SNS al email a los responsables para iniciar el Runbook DR de RDS.
- Cuando el health check vuelve a **healthy**, Route 53 hace **failback** a **PRIMARY**.

> Nota: por defecto se usa `pilotlight.invalid` para pruebas sin dominio real. Para uso real, configura `route53_zone_name` con un dominio que controles y delega los NS.

---

## Base de datos (RDS PostgreSQL) y DNS privado estable

Se usa **RDS PostgreSQL** (en lugar de Aurora) por limitaciones típicas de entornos de laboratorio/free tier.

- **Primaria**: RDS PostgreSQL **Multi-AZ** (writer).
- **Secundaria**: **read replica cross-region**.

Para desacoplar a la aplicación del endpoint físico de la DB, se crea:

- Una **Private Hosted Zone** (`pilotlight.internal` por defecto) asociada a **ambas VPCs** (primaria y secundaria).
- Un **CNAME estable**: `db.pilotlight.internal` apuntando al writer activo (por defecto el primario).

### Sobre la automatización de DR de la DB (estado actual)

Se inició un enfoque para automatizar la promoción de la réplica y el failback (Lambda + lógica de snapshots/recreación), pero **no está finalizado** en este repositorio.  
Actualmente, el enfoque recomendado es **manual**: ante failover a secundaria, los responsables deben **promover** la réplica y actualizar el “writer record” privado si aplica.

> En el código existe `enable_db_dr_automation` como variable preparatoria para esa automatización futura, pero la lógica completa no está implementada en este proyecto.

---

## Seguridad y controles implementados

### Segmentación de red

- **Subredes públicas**: únicamente para los **ALB públicos**.
- **Subredes privadas (app)**: ASGs de **Frontend** y **Backend**.
- **Subredes privadas (db)**: RDS.

### Security Groups (principio de mínimo privilegio)

- Internet → **ALB público**: `80/443`.
- **ALB público** → **Frontend**: solo `frontend_port` (por defecto `80`).
- **Frontend** → **ALB interno**: solo `backend_port` (por defecto `8080`).
- **ALB interno** → **Backend**: solo `backend_port`.
- **Backend** → **RDS**: solo `5432`.
- Acceso a **SSM** mediante **VPC Endpoints (Interface)** y SG dedicados (`443`).

### Acceso a instancias sin SSH

- Roles IAM para EC2 (Frontend/Backend) con `AmazonSSMManagedInstanceCore`.
- Endpoints privados de SSM (`ssm`, `ec2messages`, `ssmmessages`) en subredes privadas.

### Auditoría de red

- **VPC Flow Logs** hacia **S3** (bucket con bloqueo público y cifrado SSE-S3).

### Secretos y cifrado

- **Secrets Manager** en primaria con **réplica en secundaria**, cifrado con **KMS** por región.
- **RDS cifrado** con KMS (clave por región, rotación habilitada).

---

## Estructura del repositorio

```text
.
├── main.tf                  # Orquestación: network, frontend, backend
├── variables.tf             # Variables principales (Usar para configuración)
├── outputs.tf               # Outputs útiles (ALBs, ASGs, endpoints, DNS)
├── route53.tf               # Hosted zone pública + health check + failover record
├── sns.tf                   # Notificaciones por correo de eventos de desastre
├── rds.tf                   # RDS primary + replica + private DNS + Secrets/KMS
├── modules/
│   ├── network/             # VPC, subnets, NAT, flow logs, SGs, VPC endpoints SSM
│   ├── frontend/            # ALB público + ASG frontend
│   ├── backend/             # ALB interno + ASG backend
│   └── database/            # RDS primary / replica
├── userdata/
│   ├── frontend/default.sh  # User-data por defecto (servidor HTTP simple)
│   └── backend/default.sh   # User-data por defecto (servidor HTTP simple)
└── documentación/
│   ├── Backend.md           # Documentación técnica del Backend
│   └── Database.md          # Documentación técnica de Database
│   ├── Frontend.md          # Documentación técnica de Frontend
│   └── Network.md           # Documentación técnica de Network
│   ├── Route53.md           # Documentación técnica de Route53
│   ├── diagrama del proyecto.png
│   └── Runbook DR Manual CLI - RDS PostgreSQL (Pilot Light).md
```
## ⚠️ Advertencia — **Protección contra eliminación (deletion protection)**

> **Lectura obligatoria antes de desplegar en _producción_**.  
> Estas variables controlan la **protección contra eliminación** de recursos críticos (ALB, RDS, etc.). En entornos de pruebas algunos valores pueden desactivarse para facilitar ciclos rápidos de creación/ destrucción; **bajo ningún concepto** deje estas protecciones desactivadas en producción.
### ¿Qué hacen estas variables?

Variables como `enable_deletion_protection`, `db_deletion_protection` (y nombres análogos en módulos) habilitan la **protección contra borrado** a nivel de recurso. Cuando están en `true`:

- AWS impide la eliminación accidental del recurso desde la consola o desde Terraform (dependiendo del recurso).
    
- Evitan pérdida irreversible de datos o downtime por borrados accidentales.
    

Cuando están en `false` es **mucho más fácil** destruir recursos (útil en entornos de laboratorio) pero **muy peligroso** en producción.

---

## Variables relevantes en este repositorio (ejemplos)

- `enable_deletion_protection` (root / ALB, módulos frontend/backend pueden exponer su propio flag)
    
- `db_deletion_protection` / `deletion_protection` (RDS / módulo database)
    

> Revisa `variables.tf` y los `modules/*/variables.tf` si necesitas localizar flags adicionales por módulo y cambie dichos valores a "true" para evitar incidentes.