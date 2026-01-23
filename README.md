# AWS Pilot Light Disaster Recovery con Terraform

Implementación **infraestructura como código (IaC)** de una estrategia **Pilot Light Disaster Recovery** en **AWS**, usando **Terraform** e integración con **GitHub** (control de versiones, revisiones y despliegues automatizados).

Este repositorio nace como proyecto práctico de formación para **AWS Solutions Architect** y **Terraform Associate**, con tres objetivos principales:

- Poner en práctica y consolidar conocimientos de **arquitectura en AWS** y **Terraform**.
- Profundizar en patrones reales de **alta disponibilidad, resiliencia y recuperación ante desastres**.
- Construir un **portfolio profesional** orientado a roles como **Cloud Engineer / AWS Solutions Architect / Cloud Architect**.

---

## Arquitectura objetivo

La solución replica el ejemplo oficial de AWS para **Pilot Light** (DR), donde se mantiene un “mínimo” de infraestructura activa en la región secundaria (principalmente datos/replicación), y la capa de cómputo se levanta bajo demanda durante un evento de desastre.

![Pilot Light Architecture](https://docs.aws.amazon.com/es_es/whitepapers/latest/disaster-recovery-workloads-on-aws/images/pilot-light-architecture.png)

**Componentes principales (alto nivel):**

- **Route 53** para conmutación (failover) a nivel DNS.
- **Elastic Load Balancing (ELB/ALB)** para entrada de tráfico en cada región.
- **Auto Scaling Groups (ASG)** para capa de **frontend** y **aplicación**.
- **Amazon Aurora Global Database** (replicación asíncrona cross-region) como base de datos principal/replica.
- **Snapshots / backups** para recuperación adicional (según la estrategia final definida).

> Referencia de AWS:  
> https://docs.aws.amazon.com/whitepapers/latest/disaster-recovery-workloads-on-aws/disaster-recovery-options-in-the-cloud.html

---

## ¿Qué es “Pilot Light” (en este contexto)?

**Pilot Light** mantiene en la región secundaria los componentes críticos (por ejemplo, **base de datos replicada**, almacenamiento y configuración), mientras que la capa de cómputo se mantiene apagada o mínima.  
Durante un incidente, se **escala/activa** la infraestructura necesaria para restaurar el servicio con menor RTO/RPO que estrategias puramente “backup & restore”, pero con menor coste que “warm standby” o “multi-site active/active”.

---

## Alcance del repositorio

Este repositorio está diseñado para ser **público, reutilizable y desplegable rápidamente**, idealmente con configuración mínima por parte del usuario (vía variables).

> **Nota:** La lista exacta de variables “mínimas” se irá refinando a medida que el proyecto avance. Este README se actualizará con la lista definitiva y ejemplos completos.

---

## Características (planned / en progreso)

- [ ] Despliegue multi-región (Región primaria + Región secundaria).
- [ ] VPC y red por región (subnets, route tables, IGW/NAT según diseño).
- [ ] ALB/ELB por región con target groups.
- [ ] ASG para frontend y application tier (primary activo, secondary “pilot light”).
- [ ] Aurora (Primary) + Aurora Global Database (Replica cross-region).
- [ ] Route 53 failover con health checks.
- [ ] Pipelines de CI/CD (GitHub Actions): `terraform fmt`, `validate`, `plan`, `apply` (con controles).
- [ ] Documentación de runbook de DR: **failover** y **failback**.
- [ ] Buenas prácticas: tagging, módulos, separación por entornos, controles de seguridad.

---

## Requisitos

### Herramientas

- **Terraform** (versión a definir en `.terraform-version` o `required_version`).
- **AWS CLI** configurada con credenciales y región por defecto.
- Una cuenta de **AWS** con permisos suficientes para crear recursos (VPC, ALB, ASG, RDS/Aurora, Route 53, IAM, etc.).
- (Opcional) **GitHub Actions** habilitado en tu fork si planeas usar CI/CD.

### Conocimientos recomendados

- Networking en AWS (VPC, subnets, routing).
- IAM y buenas prácticas de seguridad.
- Terraform (modules, state, variables, workspaces/entornos).

---

## Estructura del repositorio

> La estructura exacta puede cambiar mientras el proyecto madura.

```text
.
├── modules/                 # Módulos reutilizables (network, alb, asg, aurora, route53, etc.)
├── envs/                    # Configuración por entorno (dev/stage/prod) o por región
├── .github/workflows/       # Pipelines de GitHub Actions
├── examples/                # Ejemplos de uso y despliegue rápido
├── docs/                    # Runbooks, decisiones, diagramas, notas de arquitectura
├── main.tf
├── variables.tf
├── outputs.tf
└── README.md
```
