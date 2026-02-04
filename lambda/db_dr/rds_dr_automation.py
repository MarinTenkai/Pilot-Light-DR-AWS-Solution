import json
import logging
import os
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Dict, Optional, Tuple

import boto3
from botocore.exceptions import ClientError

LOG = logging.getLogger()
LOG.setLevel(os.getenv("LOG_LEVEL", "INFO"))


def utc_ts() -> str:
    return datetime.now(timezone.utc).isoformat()


def jloads(s: str, default: Any) -> Any:
    try:
        return json.loads(s)
    except Exception:
        return default


@dataclass(frozen=True)
class Config:
    primary_region: str
    secondary_region: str

    primary_db_id: str
    secondary_db_id: str
    failback_db_id: str

    primary_kms_key: str
    secondary_kms_key: str

    primary_subnet_group: str
    secondary_subnet_group: str

    primary_db_sg_id: str
    secondary_db_sg_id: str

    primary_class: str
    secondary_class: str

    route53_zone_id: str
    route53_record_name: str
    route53_health_check_id: str
    ttl: int

    state_param_name: str

    # Anti-flapping para failback (opcional, default 2 ejecuciones seguidas healthy)
    failback_healthy_streak: int = 2


def load_config() -> Config:
    missing = []
    def req(name: str) -> str:
        v = os.getenv(name)
        if not v:
            missing.append(name)
            return ""
        return v

    cfg = Config(
        primary_region=req("PRIMARY_REGION"),
        secondary_region=req("SECONDARY_REGION"),

        primary_db_id=req("PRIMARY_DB_ID"),
        secondary_db_id=req("SECONDARY_DB_ID"),
        failback_db_id=req("FAILBACK_DB_ID"),

        primary_kms_key=req("PRIMARY_KMS_KEY"),
        secondary_kms_key=req("SECONDARY_KMS_KEY"),

        primary_subnet_group=req("PRIMARY_SUBNET_GROUP"),
        secondary_subnet_group=req("SECONDARY_SUBNET_GROUP"),

        primary_db_sg_id=req("PRIMARY_DB_SG_ID"),
        secondary_db_sg_id=req("SECONDARY_DB_SG_ID"),

        primary_class=req("PRIMARY_CLASS"),
        secondary_class=req("SECONDARY_CLASS"),

        route53_zone_id=req("ROUTE53_ZONE_ID"),
        route53_record_name=req("ROUTE53_RECORD_NAME"),
        route53_health_check_id=req("ROUTE53_HEALTH_CHECK_ID"),
        ttl=int(os.getenv("TTL", "30")),

        state_param_name=req("STATE_PARAM_NAME"),

        failback_healthy_streak=int(os.getenv("FAILBACK_HEALTHY_STREAK", "2")),
    )

    if missing:
        raise RuntimeError(f"Missing env vars: {', '.join(missing)}")

    return cfg


def ssm_get_state(ssm, param_name: str) -> Dict[str, Any]:
    try:
        resp = ssm.get_parameter(Name=param_name)
        return jloads(resp["Parameter"]["Value"], default={})
    except ClientError as e:
        if e.response["Error"]["Code"] == "ParameterNotFound":
            return {}
        raise


def ssm_put_state(ssm, param_name: str, state: Dict[str, Any]) -> None:
    ssm.put_parameter(
        Name=param_name,
        Value=json.dumps(state, separators=(",", ":"), sort_keys=True),
        Type="String",
        Overwrite=True,
    )


def describe_db(rds, db_id: str) -> Optional[Dict[str, Any]]:
    try:
        resp = rds.describe_db_instances(DBInstanceIdentifier=db_id)
        inst = resp["DBInstances"][0]
        return inst
    except ClientError as e:
        if e.response["Error"]["Code"] in ("DBInstanceNotFound", "DBInstanceNotFoundFault"):
            return None
        raise


def db_status(db: Dict[str, Any]) -> str:
    return db.get("DBInstanceStatus", "unknown")


def db_is_replica(db: Dict[str, Any]) -> bool:
    return bool(db.get("ReadReplicaSourceDBInstanceIdentifier"))


def db_endpoint_address(db: Dict[str, Any]) -> str:
    ep = db.get("Endpoint") or {}
    addr = ep.get("Address")
    if not addr:
        raise RuntimeError("DB endpoint address not available yet")
    return addr


def get_health_check_healthy(route53, health_check_id: str) -> Tuple[bool, Dict[str, Any]]:
    """
    Route53 devuelve observaciones de varios checkers.
    Consideramos healthy si la mayoría reporta 'Healthy'.
    """
    resp = route53.get_health_check_status(HealthCheckId=health_check_id)
    obs = resp.get("HealthCheckObservations", [])
    statuses = []
    for o in obs:
        sr = o.get("StatusReport", {})
        st = sr.get("Status")
        if st:
            statuses.append(st)

    if not statuses:
        # Conservador: si no hay datos, NO disparamos cambios.
        return True, {"observations": 0, "healthy": 0, "unhealthy": 0, "decision": "no-data=>healthy"}

    healthy = sum(1 for s in statuses if s == "Healthy")
    unhealthy = len(statuses) - healthy
    decision = healthy >= (len(statuses) // 2 + 1)

    detail = {
        "observations": len(statuses),
        "healthy": healthy,
        "unhealthy": unhealthy,
        "decision": decision,
    }
    return decision, detail


def upsert_private_cname(route53, zone_id: str, record_name: str, target: str, ttl: int) -> None:
    name = record_name if record_name.endswith(".") else record_name + "."
    value = target if target.endswith(".") else target + "."

    route53.change_resource_record_sets(
        HostedZoneId=zone_id,
        ChangeBatch={
            "Comment": f"DB DR automation {utc_ts()}",
            "Changes": [
                {
                    "Action": "UPSERT",
                    "ResourceRecordSet": {
                        "Name": name,
                        "Type": "CNAME",
                        "TTL": ttl,
                        "ResourceRecords": [{"Value": value}],
                    },
                }
            ],
        },
    )


def promote_replica_if_needed(rds, db_id: str) -> str:
    """
    Devuelve: 'promote-called' | 'already-writer' | 'waiting' (si no está en estado válido)
    """
    db = describe_db(rds, db_id)
    if not db:
        raise RuntimeError(f"DB {db_id} not found")

    if not db_is_replica(db):
        return "already-writer"

    st = db_status(db)
    if st not in ("available",):
        return f"waiting:{st}"

    try:
        rds.promote_read_replica(DBInstanceIdentifier=db_id)
        return "promote-called"
    except ClientError as e:
        code = e.response["Error"]["Code"]
        # Si está ya promovida o en transición
        if code in ("InvalidDBInstanceState", "InvalidDBInstanceStateFault"):
            return f"waiting:{st}"
        raise


def create_cross_region_replica(
    rds_target,
    *,
    target_db_id: str,
    source_db_arn: str,
    source_region: str,
    instance_class: str,
    subnet_group: str,
    sg_id: str,
    kms_key: str,
    multi_az: bool,
) -> str:
    try:
        rds_target.create_db_instance_read_replica(
            DBInstanceIdentifier=target_db_id,
            SourceDBInstanceIdentifier=source_db_arn,
            SourceRegion=source_region,
            DBInstanceClass=instance_class,
            DBSubnetGroupName=subnet_group,
            VpcSecurityGroupIds=[sg_id],
            PubliclyAccessible=False,
            KmsKeyId=kms_key,
            MultiAZ=multi_az,
            CopyTagsToSnapshot=True,
        )
        return "create-called"
    except ClientError as e:
        code = e.response["Error"]["Code"]
        if code in ("DBInstanceAlreadyExists", "DBInstanceAlreadyExistsFault"):
            return "already-exists"
        raise


def delete_db_instance(rds, db_id: str) -> str:
    """
    Borra una instancia (para reconstruir réplica).
    Por seguridad, crea final snapshot (si es posible).
    """
    snap_id = f"{db_id}-final-{datetime.now(timezone.utc).strftime('%Y%m%d%H%M%S')}"
    # RDS limita caracteres; snap_id es seguro (letras/números/guiones)
    try:
        rds.delete_db_instance(
            DBInstanceIdentifier=db_id,
            SkipFinalSnapshot=False,
            FinalDBSnapshotIdentifier=snap_id,
            DeleteAutomatedBackups=True,
        )
        return f"delete-called:snapshot:{snap_id}"
    except ClientError as e:
        code = e.response["Error"]["Code"]
        if code in ("InvalidDBInstanceState", "InvalidDBInstanceStateFault"):
            return "waiting"
        if code in ("DBInstanceNotFound", "DBInstanceNotFoundFault"):
            return "not-found"
        # Si deletion protection está activado, fallará aquí:
        raise


def ensure_state_defaults(state: Dict[str, Any]) -> Dict[str, Any]:
    # Estado mínimo
    state.setdefault("active", "primary")   # dónde está el writer "real" según nuestra automatización
    state.setdefault("phase", "steady")
    state.setdefault("ts", utc_ts())
    state.setdefault("hc", {})
    state.setdefault("failback_healthy_streak", 0)
    return state


def handler(event, context):
    cfg = load_config()

    # Clientes por región
    rds_primary = boto3.client("rds", region_name=cfg.primary_region)
    rds_secondary = boto3.client("rds", region_name=cfg.secondary_region)

    # Route53 es global, pero boto3 requiere "alguna" región; us-east-1 es estándar
    route53 = boto3.client("route53", region_name="us-east-1")

    # El state param lo guardas en la región secundaria (así está tu Terraform)
    ssm = boto3.client("ssm", region_name=cfg.secondary_region)

    state = ensure_state_defaults(ssm_get_state(ssm, cfg.state_param_name))

    # Señal: health check del ALB primario
    hc_ok, hc_detail = get_health_check_healthy(route53, cfg.route53_health_check_id)

    # Anti-flapping: exigimos N seguidos healthy para iniciar failback
    if hc_ok:
        state["failback_healthy_streak"] = int(state.get("failback_healthy_streak", 0)) + 1
    else:
        state["failback_healthy_streak"] = 0

    state["hc"] = {
        "primary_hc_healthy": hc_ok,
        "detail": hc_detail,
        "checked_at": utc_ts(),
    }

    desired = "secondary" if not hc_ok else "primary"
    # Para failback, esperamos a streak>=N
    if desired == "primary" and state["active"] == "secondary":
        if state["failback_healthy_streak"] < cfg.failback_healthy_streak:
            desired = "secondary"

    active = state.get("active", "primary")
    phase = state.get("phase", "steady")

    LOG.info(json.dumps({
        "msg": "tick",
        "desired": desired,
        "active": active,
        "phase": phase,
        "hc_ok": hc_ok,
        "hc_detail": hc_detail,
    }))

    # Si estamos estables pero cambia el "desired", arrancamos transición
    if phase == "steady" and desired != active:
        if desired == "secondary" and active == "primary":
            phase = "failover_promote_secondary"
        elif desired == "primary" and active == "secondary":
            phase = "failback_create_replica_primary"

        state["phase"] = phase
        state["transition_started_at"] = utc_ts()

    # -------- FAILOVER --------
    if state["phase"] == "failover_promote_secondary":
        res = promote_replica_if_needed(rds_secondary, cfg.secondary_db_id)
        state["last_action"] = {"at": utc_ts(), "action": "promote_secondary", "result": res}

        # Si ya es writer o ya lanzamos promote, pasamos a esperar disponibilidad como writer
        db_sec = describe_db(rds_secondary, cfg.secondary_db_id)
        if db_sec and db_status(db_sec) == "available" and not db_is_replica(db_sec):
            state["phase"] = "failover_update_dns"

    if state["phase"] == "failover_update_dns":
        db_sec = describe_db(rds_secondary, cfg.secondary_db_id)
        if not db_sec:
            raise RuntimeError("Secondary DB missing during failover_update_dns")

        if db_status(db_sec) != "available" or db_is_replica(db_sec):
            state["last_action"] = {"at": utc_ts(), "action": "wait_secondary_writer", "result": db_status(db_sec)}
        else:
            target = db_endpoint_address(db_sec)
            upsert_private_cname(route53, cfg.route53_zone_id, cfg.route53_record_name, target, cfg.ttl)

            state["last_action"] = {"at": utc_ts(), "action": "dns_to_secondary", "target": target}
            state["active"] = "secondary"
            state["phase"] = "steady"
            state["ts"] = utc_ts()

    # -------- FAILBACK --------
    if state["phase"] == "failback_create_replica_primary":
        # Fuente: writer en secundaria
        db_sec = describe_db(rds_secondary, cfg.secondary_db_id)
        if not db_sec or db_status(db_sec) != "available":
            state["last_action"] = {"at": utc_ts(), "action": "wait_secondary_available", "result": db_status(db_sec) if db_sec else "missing"}
        else:
            if db_is_replica(db_sec):
                # Si por lo que sea nunca se promovió, no podemos failback correcto; primero hay que promover.
                state["last_action"] = {"at": utc_ts(), "action": "secondary_not_writer", "result": "still-replica"}
            else:
                db_fb = describe_db(rds_primary, cfg.failback_db_id)
                if db_fb:
                    state["last_action"] = {"at": utc_ts(), "action": "failback_instance_exists", "status": db_status(db_fb)}
                    state["phase"] = "failback_promote_primary"
                else:
                    res = create_cross_region_replica(
                        rds_primary,
                        target_db_id=cfg.failback_db_id,
                        source_db_arn=db_sec["DBInstanceArn"],
                        source_region=cfg.secondary_region,
                        instance_class=cfg.primary_class,
                        subnet_group=cfg.primary_subnet_group,
                        sg_id=cfg.primary_db_sg_id,
                        kms_key=cfg.primary_kms_key,
                        multi_az=True,
                    )
                    state["last_action"] = {"at": utc_ts(), "action": "create_failback_replica_primary", "result": res}
                    state["phase"] = "failback_promote_primary"

    if state["phase"] == "failback_promote_primary":
        db_fb = describe_db(rds_primary, cfg.failback_db_id)
        if not db_fb:
            state["last_action"] = {"at": utc_ts(), "action": "wait_failback_exists", "result": "missing"}
        else:
            st = db_status(db_fb)
            if st != "available":
                state["last_action"] = {"at": utc_ts(), "action": "wait_failback_available", "result": st}
            else:
                if db_is_replica(db_fb):
                    res = promote_replica_if_needed(rds_primary, cfg.failback_db_id)
                    state["last_action"] = {"at": utc_ts(), "action": "promote_failback_primary", "result": res}
                else:
                    state["phase"] = "failback_update_dns"

    if state["phase"] == "failback_update_dns":
        db_fb = describe_db(rds_primary, cfg.failback_db_id)
        if not db_fb:
            raise RuntimeError("Failback primary DB missing during failback_update_dns")

        if db_status(db_fb) != "available" or db_is_replica(db_fb):
            state["last_action"] = {"at": utc_ts(), "action": "wait_failback_writer", "result": db_status(db_fb)}
        else:
            target = db_endpoint_address(db_fb)
            upsert_private_cname(route53, cfg.route53_zone_id, cfg.route53_record_name, target, cfg.ttl)
            state["last_action"] = {"at": utc_ts(), "action": "dns_to_primary_failback", "target": target}

            state["active"] = "primary"
            state["phase"] = "rebuild_secondary_delete_old"
            state["ts"] = utc_ts()

    # -------- REBUILD DR (secondary vuelve a ser réplica) --------
    if state["phase"] == "rebuild_secondary_delete_old":
        # Queremos que SECONDARY_DB_ID vuelva a ser read replica del writer en primaria (FAILBACK_DB_ID).
        db_sec = describe_db(rds_secondary, cfg.secondary_db_id)
        if not db_sec:
            state["phase"] = "rebuild_secondary_create_replica"
        else:
            # Si ya es réplica, perfecto.
            if db_is_replica(db_sec):
                state["last_action"] = {"at": utc_ts(), "action": "secondary_already_replica", "status": db_status(db_sec)}
                state["phase"] = "steady"
                state["ts"] = utc_ts()
            else:
                # Es standalone (promovida): hay que borrarla para recrearla como réplica
                res = delete_db_instance(rds_secondary, cfg.secondary_db_id)
                state["last_action"] = {"at": utc_ts(), "action": "delete_old_secondary_writer", "result": res}
                state["phase"] = "rebuild_secondary_wait_delete"

    if state["phase"] == "rebuild_secondary_wait_delete":
        db_sec = describe_db(rds_secondary, cfg.secondary_db_id)
        if db_sec:
            state["last_action"] = {"at": utc_ts(), "action": "wait_secondary_deleted", "status": db_status(db_sec)}
        else:
            state["phase"] = "rebuild_secondary_create_replica"

    if state["phase"] == "rebuild_secondary_create_replica":
        db_fb = describe_db(rds_primary, cfg.failback_db_id)
        if not db_fb or db_status(db_fb) != "available" or db_is_replica(db_fb):
            state["last_action"] = {"at": utc_ts(), "action": "wait_primary_writer_for_replica_create", "result": db_status(db_fb) if db_fb else "missing"}
        else:
            res = create_cross_region_replica(
                rds_secondary,
                target_db_id=cfg.secondary_db_id,
                source_db_arn=db_fb["DBInstanceArn"],
                source_region=cfg.primary_region,
                instance_class=cfg.secondary_class,
                subnet_group=cfg.secondary_subnet_group,
                sg_id=cfg.secondary_db_sg_id,
                kms_key=cfg.secondary_kms_key,
                multi_az=False,
            )
            state["last_action"] = {"at": utc_ts(), "action": "create_secondary_replica", "result": res}
            state["phase"] = "rebuild_secondary_wait_replica"

    if state["phase"] == "rebuild_secondary_wait_replica":
        db_sec = describe_db(rds_secondary, cfg.secondary_db_id)
        if not db_sec:
            state["last_action"] = {"at": utc_ts(), "action": "wait_secondary_replica_exists", "result": "missing"}
        else:
            st = db_status(db_sec)
            if st != "available":
                state["last_action"] = {"at": utc_ts(), "action": "wait_secondary_replica_available", "result": st}
            else:
                if not db_is_replica(db_sec):
                    state["last_action"] = {"at": utc_ts(), "action": "secondary_not_replica_yet", "result": "unexpected-standalone"}
                else:
                    state["last_action"] = {"at": utc_ts(), "action": "secondary_replica_ready", "result": "ok"}
                    state["phase"] = "steady"
                    state["ts"] = utc_ts()

    # Persistimos estado al final (siempre)
    state["updated_at"] = utc_ts()
    ssm_put_state(ssm, cfg.state_param_name, state)

    return {
        "ok": True,
        "desired": desired,
        "active": state.get("active"),
        "phase": state.get("phase"),
        "hc_ok": hc_ok,
        "updated_at": state.get("updated_at"),
    }
