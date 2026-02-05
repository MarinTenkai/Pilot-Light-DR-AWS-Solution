## Runbook DR Manual CLI — RDS PostgreSQL (Pilot Light)

### Objetivo
Este proyecto implementa una estrategia **Pilot Light** multi-región con:

- **Región primaria** (producción): RDS PostgreSQL **Multi-AZ** (writer)
- **Región secundaria** (DR): RDS PostgreSQL **Read Replica cross-region** (standby)
- **DNS interno estable**: `db.pilotlight.internal` (Route53 Private Hosted Zone) para que la aplicación no cambie de host

En un desastre regional, haremos **DR manual**:

1) **Failover manual**: promover la read replica en la región secundaria (se convierte en writer).  
2) Mover el **CNAME privado** (`db.pilotlight.internal`) para que apunte al writer de la región secundaria.  
3) **Failback manual**: reconstruir la topología hacia primaria (crear nueva réplica en primaria desde el writer secundario, promoverla, mover DNS, y recrear la réplica en secundaria).

---

# 0) Requisitos previos

## 0.1 Herramientas
- Windows PowerShell (5.1 o superior) o PowerShell 7+
- AWS CLI v2 instalado y configurado:
  - `aws configure` o perfiles con `AWS_PROFILE`
- Permisos mínimos IAM (lectura + cambios DNS + acciones RDS):
  - `rds:DescribeDBInstances`
  - `rds:PromoteReadReplica`
  - `rds:CreateDBInstanceReadReplica`
  - `rds:DeleteDBInstance`
  - `route53:ListHostedZonesByName`
  - `route53:ListResourceRecordSets`
  - `route53:ChangeResourceRecordSets`
  - `sts:GetCallerIdentity`

## 0.2 Configuración: variables PowerShell
Ajusta `Env` a tu `terraform.workspace`. Si usas otros IDs, cámbialos aquí.

```powershell
# ========== Regiones ==========
$PrimaryRegion   = "eu-south-2"   # España
$SecondaryRegion = "eu-west-3"    # París

# ========== Entorno (terraform.workspace) ==========
$Env = "dev"  # <-- CAMBIA ESTO

# ========== RDS Identifiers (según tu módulo) ==========
$PrimaryDbId   = "$Env-rds-primary"
$SecondaryDbId = "$Env-rds-secondary"

# Failback: nueva DB en primaria creada desde el writer secundario
$FailbackPrimaryDbId = "$Env-rds-primary-failback"

# ========== DNS interno (Private Hosted Zone) ==========
$PrivateZoneName = "pilotlight.internal"
$DbWriterRecord  = "db.pilotlight.internal"

# TTL del record (debe coincidir con terraform si aplica)
$Ttl = 30
```

## 0.3 Validación rápida de credenciales
```powershell
aws sts get-caller-identity | Out-String
```

# 1) Baseline — comprobaciones antes de DR

## 1.1 Estado del writer en primaria

```powershell
aws rds describe-db-instances `
  --region $PrimaryRegion `
  --db-instance-identifier $PrimaryDbId `
  --query "DBInstances[0].{Id:DBInstanceIdentifier,Status:DBInstanceStatus,MultiAZ:MultiAZ,ReplicaSource:ReadReplicaSourceDBInstanceIdentifier,Endpoint:Endpoint.Address,Arn:DBInstanceArn}" | Out-String
```

Esperado:

- `Status` = `available`
    
- `MultiAZ` = `true`
    
- `ReplicaSource` = `null` (no es réplica)
    
- `Endpoint` presente
## 1.2 Estado de la réplica en secundaria
```powershell
aws rds describe-db-instances `
  --region $SecondaryRegion `
  --db-instance-identifier $SecondaryDbId `
  --query "DBInstances[0].{Id:DBInstanceIdentifier,Status:DBInstanceStatus,MultiAZ:MultiAZ,ReplicaSource:ReadReplicaSourceDBInstanceIdentifier,Endpoint:Endpoint.Address,Arn:DBInstanceArn}" | Out-String
```

Esperado:

- `Status` = `available`
    
- `ReplicaSource` **NO null** (es réplica)
    
- `MultiAZ` normalmente `false`
    

## 1.3 DNS interno: localizar Hosted Zone ID y ver el CNAME actual

### 1.3.1 Obtener Hosted Zone ID por nombre
```powershell
$PrivateZoneId = aws route53 list-hosted-zones-by-name `
  --dns-name $PrivateZoneName `
  --query "HostedZones[?Name=='$PrivateZoneName.'].Id | [0]" `
  --output text

$PrivateZoneId = $PrivateZoneId -replace ".*/hostedzone/",""
$PrivateZoneId
```
## 1.3.2 Ver el record `db.pilotlight.internal`
```powershell
aws route53 list-resource-record-sets `
  --hosted-zone-id $PrivateZoneId `
  --query "ResourceRecordSets[?Name=='$DbWriterRecord.']" | Out-String
```
Guarda el valor actual del CNAME (debe ser endpoint del primario).
# 2) FAILOVER MANUAL (Primaria caída → Secundaria writer)

> Objetivo: convertir la réplica secundaria en writer y mover el CNAME a esa región.

## 2.1 Promover la read replica en secundaria
```powershell
aws rds promote-read-replica `
  --region $SecondaryRegion `
  --db-instance-identifier $SecondaryDbId | Out-String
```
Esto inicia una operación async.

## 2.2 Esperar hasta que la DB secundaria sea writer y esté `available`

Repite este comando hasta que:

- `Status` sea `available`
    
- `ReplicaSource` sea `null`
```powershell
aws rds describe-db-instances `
  --region $SecondaryRegion `
  --db-instance-identifier $SecondaryDbId `
  --query "DBInstances[0].{Status:DBInstanceStatus,ReplicaSource:ReadReplicaSourceDBInstanceIdentifier,Endpoint:Endpoint.Address}" | Out-String
```
### 2.2.1 Guardar el endpoint del nuevo writer secundario
```powershell
$SecondaryWriterEndpoint = aws rds describe-db-instances `
  --region $SecondaryRegion `
  --db-instance-identifier $SecondaryDbId `
  --query "DBInstances[0].Endpoint.Address" `
  --output text

$SecondaryWriterEndpoint
```
## 2.3 Mover el CNAME `db.pilotlight.internal` al writer secundario

Creamos un UPSERT (cambia o crea):
```powershell
$ChangeBatch = @"
{
  "Comment": "Manual DR failover to secondary writer",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "$DbWriterRecord.",
        "Type": "CNAME",
        "TTL": $Ttl,
        "ResourceRecords": [
          { "Value": "$SecondaryWriterEndpoint." }
        ]
      }
    }
  ]
}
"@

$ChangeBatch | Out-File -Encoding ascii -FilePath .\r53-change-failover.json
aws route53 change-resource-record-sets --hosted-zone-id $PrivateZoneId --change-batch file://r53-change-failover.json | Out-String
```
## 2.4 Verificación final del failover

### 2.4.1 Comprobar el CNAME
```powershell
aws route53 list-resource-record-sets `
  --hosted-zone-id $PrivateZoneId `
  --query "ResourceRecordSets[?Name=='$DbWriterRecord.']" | Out-String
```
Debe apuntar al endpoint secundario.

### 2.4.2 Confirmar que secundaria ya no es réplica
```powershell
aws rds describe-db-instances `
  --region $SecondaryRegion `
  --db-instance-identifier $SecondaryDbId `
  --query "DBInstances[0].{Status:DBInstanceStatus,ReplicaSource:ReadReplicaSourceDBInstanceIdentifier}" | Out-String
```
# 3) FAILBACK MANUAL (Vuelta a primaria como writer)

> Importante: en RDS PostgreSQL, tras promover la réplica, **no puedes “volverla a convertir” en réplica**.  
> Failback correcto:
> 
> 1. Crear una nueva réplica en primaria desde el writer de secundaria
>     
> 2. Promoverla (writer en primaria)
>     
> 3. Mover el DNS a ese writer en primaria
>     
> 4. Recrear la réplica en secundaria apuntando al nuevo writer primario
>     

## 3.1 Crear una réplica en primaria desde el writer secundario

### 3.1.1 Obtener el ARN del writer secundario
```powershell
$SecondaryWriterArn = aws rds describe-db-instances `
  --region $SecondaryRegion `
  --db-instance-identifier $SecondaryDbId `
  --query "DBInstances[0].DBInstanceArn" `
  --output text

$SecondaryWriterArn
```
### 3.1.2 Crear la read replica en primaria (nuevo DB instance)

> Nota: algunas opciones (subnet group, SG, KMS) pueden ser necesarias según tu configuración.  
> Si tu entorno requiere especificarlas, añade:
> 
> - `--db-subnet-group-name ...`
>     
> - `--vpc-security-group-ids ...`
>     
> - `--kms-key-id ...`
>     
> - `--db-instance-class ...`
>     
> 
> Aquí vamos con la forma más compatible: especificar SourceRegion y el identifier.
```powershell
aws rds create-db-instance-read-replica `
  --region $PrimaryRegion `
  --db-instance-identifier $FailbackPrimaryDbId `
  --source-db-instance-identifier $SecondaryWriterArn `
  --source-region $SecondaryRegion | Out-String
```
## 3.2 Esperar a que la réplica en primaria esté `available`
```powershell
aws rds describe-db-instances `
  --region $PrimaryRegion `
  --db-instance-identifier $FailbackPrimaryDbId `
  --query "DBInstances[0].{Status:DBInstanceStatus,ReplicaSource:ReadReplicaSourceDBInstanceIdentifier,Endpoint:Endpoint.Address}" | Out-String
```
Debe llegar a `available` con `ReplicaSource` NO null.

## 3.3 Promover la réplica en primaria (se convierte en writer)
```powershell
aws rds promote-read-replica `
  --region $PrimaryRegion `
  --db-instance-identifier $FailbackPrimaryDbId | Out-String
```
Esperar hasta que:

- `Status` = `available`
    
- `ReplicaSource` = `null`\
```powershell
aws rds describe-db-instances `
  --region $PrimaryRegion `
  --db-instance-identifier $FailbackPrimaryDbId `
  --query "DBInstances[0].{Status:DBInstanceStatus,ReplicaSource:ReadReplicaSourceDBInstanceIdentifier,Endpoint:Endpoint.Address}" | Out-String
```
### 3.3.1 Guardar endpoint writer en primaria
```powershell
$PrimaryWriterEndpoint = aws rds describe-db-instances `
  --region $PrimaryRegion `
  --db-instance-identifier $FailbackPrimaryDbId `
  --query "DBInstances[0].Endpoint.Address" `
  --output text

$PrimaryWriterEndpoint
```
## 3.4 Mover el CNAME de vuelta a primaria
```powershell
$ChangeBatch = @"
{
  "Comment": "Manual DR failback to primary writer",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "$DbWriterRecord.",
        "Type": "CNAME",
        "TTL": $Ttl,
        "ResourceRecords": [
          { "Value": "$PrimaryWriterEndpoint." }
        ]
      }
    }
  ]
}
"@

$ChangeBatch | Out-File -Encoding ascii -FilePath .\r53-change-failback.json
aws route53 change-resource-record-sets --hosted-zone-id $PrivateZoneId --change-batch file://r53-change-failback.json | Out-String
```
Verifica:
```powershell
aws route53 list-resource-record-sets `
  --hosted-zone-id $PrivateZoneId `
  --query "ResourceRecordSets[?Name=='$DbWriterRecord.']" | Out-String
```
# 4) Reconstruir la réplica en secundaria (para dejar DR listo otra vez)

> Ahora la DB secundaria (la que promoviste) es standalone writer.  
> Para volver a tener DR listo, debes **recrear** una read replica en secundaria desde el writer primario.

## 4.1 Borrar la DB secundaria antigua (standalone)

⚠️ Esto es destructivo. Asegúrate de que ya no la necesitas como writer.
```powershell
aws rds delete-db-instance `
  --region $SecondaryRegion `
  --db-instance-identifier $SecondaryDbId `
  --skip-final-snapshot | Out-String
```
Espera a que desaparezca:
```powershell
aws rds describe-db-instances `
  --region $SecondaryRegion `
  --db-instance-identifier $SecondaryDbId | Out-String
```
Cuando devuelva “NotFound”, ya está.

## 4.2 Crear de nuevo la réplica en secundaria desde el writer primario

### 4.2.1 Obtener ARN del writer primario (failback DB)
```powershell
$PrimaryWriterArn = aws rds describe-db-instances `
  --region $PrimaryRegion `
  --db-instance-identifier $FailbackPrimaryDbId `
  --query "DBInstances[0].DBInstanceArn" `
  --output text

$PrimaryWriterArn
```
### 4.2.2 Crear réplica en secundaria con el mismo ID de antes
```powershell
aws rds create-db-instance-read-replica `
  --region $SecondaryRegion `
  --db-instance-identifier $SecondaryDbId `
  --source-db-instance-identifier $PrimaryWriterArn `
  --source-region $PrimaryRegion | Out-String
```
## 4.3 Verificación final (estado DR “restaurado”)
```powershell
aws rds describe-db-instances `
  --region $SecondaryRegion `
  --db-instance-identifier $SecondaryDbId `
  --query "DBInstances[0].{Status:DBInstanceStatus,ReplicaSource:ReadReplicaSourceDBInstanceIdentifier,Endpoint:Endpoint.Address}" | Out-String
```
Esperado:

- `Status: available`
    
- `ReplicaSource` **NO null** (vuelve a ser réplica)
# 5) Checklist de verificación (para documentación)

## Failover (primaria → secundaria)

-  `promote-read-replica` ejecutado en secundaria
    
-  Secundaria `available` y `ReplicaSource = null`
    
-  `db.pilotlight.internal` apunta a endpoint de secundaria
    
-  Aplicación conecta contra el mismo hostname (`db.pilotlight.internal`)
    

## Failback (secundaria → primaria)

-  Creada `dev-rds-primary-failback` (o el ID que uses) como réplica en primaria desde writer secundario
    
-  Promovida a writer en primaria (`ReplicaSource = null`)
    
-  `db.pilotlight.internal` vuelve a endpoint de primaria
    
-  Recreada réplica en secundaria desde el nuevo writer primario
    

---

# 6) Notas operativas importantes

- **RDS PostgreSQL**: una réplica promovida **no puede volver a ser réplica**. Hay que **recrear**.
    
- Este runbook asume que el **DNS interno** es la forma de switchear a nivel de aplicación.
    
- Si Terraform gestiona el record y no tienes `ignore_changes`, cualquier cambio manual puede revertirse en un futuro `terraform apply`.
    
    - Decide si tu postura es “Terraform manda” o “permitimos drift en DR”.