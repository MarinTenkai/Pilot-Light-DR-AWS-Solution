import os, json, time
import boto3
import botocore

PRIMARY_REGION   = os.environ["PRIMARY_REGION"]
SECONDARY_REGION = os.environ["SECONDARY_REGION"]

PRIMARY_DB_ID    = os.environ["PRIMARY_DB_ID"]
SECONDARY_DB_ID  = os.environ["SECONDARY_DB_ID"]

FAILBACK_DB_ID   = os.environ["FAILBACK_DB_ID"]

PRIMARY_KMS_KEY   = os.environ["PRIMARY_KMS_KEY"]
SECONDARY_KMS_KEY = os.environ["SECONDARY_KMS_KEY"]

PRIMARY_SUBNET_GROUP    = os.environ["PRIMARY_SUBNET_GROUP"]
SECONDARY_SUBNET_GROUP  = os.environ["SECONDARY_SUBNET_GROUP"]

PRIMARY_DB_SG_ID   = os.environ["PRIMARY_DB_SG_ID"]
SECONDARY_DB_SG_ID = os.environ["SECONDARY_DB_SG_ID"]

PRIMARY_CLASS   = os.environ["PRIMARY_CLASS"]
SECONDARY_CLASS = os.environ["SECONDARY_CLASS"]

HZ_ID       = os.environ["ROUTE53_ZONE_ID"]
RECORD_NAME = os.environ["ROUTE53_RECORD_NAME"]
HEALTHCHECK_ID = os.environ["ROUTE53_HEALTH_CHECK_ID"]

STATE_PARAM = os.environ["STATE_PARAM_NAME"]
TTL         = int(os.environ.get("TTL", "30"))

# Clients
route53 = boto3.client("route53")  # global
ssm     = boto3.client("ssm", region_name=SECONDARY_REGION)
rds_p   = boto3.client("rds", region_name=PRIMARY_REGION)
rds_s   = boto3.client("rds", region_name=SECONDARY_REGION)

def _now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

def get_state():
    """
    Estado persistente (SSM en región secundaria).
    - active: "primary" | "secondary"
    - phase: fases del state machine
    - primary_writer_id: qué DBInstanceIdentifier es el writer en primaria (por si failback crea otro ID)
    """
    try:
        raw = ssm.get_parameter(Name=STATE_PARAM)["Parameter"]["Value"]
        st = json.loads(raw)
        if "primary_writer_id" not in st:
            st["primary_writer_id"] = PRIMARY_DB_ID
        return st
    except ssm.exceptions.ParameterNotFound:
        st = {"active":"primary","phase":"steady","primary_writer_id": PRIMARY_DB_ID, "ts":_now()}
        ssm.put_parameter(Name=STATE_PARAM, Value=json.dumps(st), Type="String", Overwrite=True)
        return st
    except Exception:
        return {"active":"primary","phase":"steady","primary_writer_id": PRIMARY_DB_ID, "ts":_now()}

def put_state(state):
    state["ts"] = _now()
    ssm.put_parameter(Name=STATE_PARAM, Value=json.dumps(state), Type="String", Overwrite=True)

def describe_db(client, dbid):
    try:
        resp = client.describe_db_instances(DBInstanceIdentifier=dbid)
        db = resp["DBInstances"][0]
        status = db.get("DBInstanceStatus")
        addr = db.get("Endpoint", {}).get("Address")
        arn  = db.get("DBInstanceArn")
        source = db.get("ReadReplicaSourceDBInstanceIdentifier")
        return {"exists":True, "status":status, "address":addr, "arn":arn, "source":source}
    except botocore.exceptions.ClientError as e:
        code = e.response["Error"]["Code"]
        if code in ("DBInstanceNotFound", "DBInstanceNotFoundFault"):
            return {"exists":False}
        raise
    except botocore.exceptions.EndpointConnectionError:
        return {"exists":True, "status":"api_unreachable"}

def upsert_dns(target):
    change = {
        "Action":"UPSERT",
        "ResourceRecordSet":{
            "Name":RECORD_NAME,
            "Type":"CNAME",
            "TTL": TTL,
            "ResourceRecords":[{"Value": target}]
        }
    }
    route53.change_resource_record_sets(
        HostedZoneId=HZ_ID,
        ChangeBatch={"Comment":"DB DR automation (triggered by Route53 HC)", "Changes":[change]}
    )

def get_route53_hc_is_healthy():
    """
    Trigger DR SOLO en base al health check del ALB primario.
    Devuelve:
      - True  => HC Healthy
      - False => HC Unhealthy
      - None  => no se pudo determinar (no actuamos)
    """
    try:
        resp = route53.get_health_check_status(HealthCheckId=HEALTHCHECK_ID)
        obs = resp.get("HealthCheckObservations", [])
        if not obs:
            return None

        statuses = []
        for o in obs:
            sr = o.get("StatusReport", {})
            statuses.append(sr.get("Status"))

        healthy = sum(1 for s in statuses if s == "Healthy")
        not_healthy = sum(1 for s in statuses if s != "Healthy")

        return healthy > not_healthy
    except Exception:
        return None

def handler(event, context):
    st = get_state()

    hc = get_route53_hc_is_healthy()

    primary_writer_id = st.get("primary_writer_id", PRIMARY_DB_ID)

    p_writer = describe_db(rds_p, primary_writer_id)
    s_db = describe_db(rds_s, SECONDARY_DB_ID)

    # Si no podemos leer el health check, NO hacemos DR. Solo mantenemos el DNS si se puede.
    if hc is None:
        if st.get("active") == "primary":
            if p_writer.get("exists") and p_writer.get("status") == "available" and p_writer.get("address"):
                try:
                    upsert_dns(p_writer["address"])
                except Exception:
                    pass
        else:
            if s_db.get("exists") and s_db.get("status") == "available" and s_db.get("address"):
                try:
                    upsert_dns(s_db["address"])
                except Exception:
                    pass
        return {"state": st, "action":"none", "reason":"hc_unknown"}

    # ACTIVE = PRIMARY
    if st.get("active") == "primary":
        if hc is True:
            if p_writer.get("exists") and p_writer.get("status") == "available" and p_writer.get("address"):
                try:
                    upsert_dns(p_writer["address"])
                except Exception:
                    pass
            return {"state": st, "action":"none", "reason":"hc_healthy_primary_active"}

        # hc == False => activar DR DB en secundaria
        if s_db.get("exists") and s_db.get("source"):
            if st.get("phase") != "promoting_secondary":
                rds_s.promote_read_replica(DBInstanceIdentifier=SECONDARY_DB_ID)
                st["phase"] = "promoting_secondary"
                put_state(st)
                return {"state": st, "action":"promote_secondary"}
            return {"state": st, "action":"wait_secondary_promotion"}

        if s_db.get("exists") and s_db.get("status") == "available" and (not s_db.get("source")) and s_db.get("address"):
            upsert_dns(s_db["address"])
            st["active"] = "secondary"
            st["phase"]  = "steady"
            put_state(st)
            return {"state": st, "action":"dns_to_secondary"}

        return {"state": st, "action":"wait", "reason":"secondary_not_ready_for_failover"}

    # ACTIVE = SECONDARY
    if st.get("active") == "secondary":
        if hc is False:
            if s_db.get("exists") and s_db.get("status") == "available" and s_db.get("address"):
                try:
                    upsert_dns(s_db["address"])
                except Exception:
                    pass
            return {"state": st, "action":"none", "reason":"hc_unhealthy_secondary_active"}

        # hc == True => FAILBACK hacia primaria
        fb = describe_db(rds_p, FAILBACK_DB_ID)

        if st.get("phase") == "steady":
            st["phase"] = "creating_primary_failback"
            put_state(st)

        if st.get("phase") == "creating_primary_failback":
            if not fb.get("exists"):
                if not s_db.get("arn"):
                    return {"state": st, "action":"wait", "reason":"secondary_arn_missing"}

                rds_p.create_db_instance_read_replica(
                    DBInstanceIdentifier=FAILBACK_DB_ID,
                    SourceDBInstanceIdentifier=s_db["arn"],
                    DBInstanceClass=PRIMARY_CLASS,
                    DBSubnetGroupName=PRIMARY_SUBNET_GROUP,
                    VpcSecurityGroupIds=[PRIMARY_DB_SG_ID],
                    KmsKeyId=PRIMARY_KMS_KEY,
                    PubliclyAccessible=False,
                    MultiAZ=True,
                    CopyTagsToSnapshot=True
                )
                return {"state": st, "action":"create_failback_replica_primary"}

            if fb.get("status") == "available":
                st["phase"] = "promoting_primary_failback"
                put_state(st)

            return {"state": st, "action":"wait_failback_replica_primary"}

        if st.get("phase") == "promoting_primary_failback":
            fb2 = describe_db(rds_p, FAILBACK_DB_ID)
            if fb2.get("exists") and fb2.get("status") == "available":
                if fb2.get("source"):
                    rds_p.promote_read_replica(DBInstanceIdentifier=FAILBACK_DB_ID)
                    return {"state": st, "action":"promote_failback_primary"}

                if fb2.get("address"):
                    upsert_dns(fb2["address"])
                    st["active"] = "primary"
                    st["phase"]  = "rebuilding_secondary_replica"
                    st["primary_writer_id"] = FAILBACK_DB_ID
                    put_state(st)
                    return {"state": st, "action":"dns_to_primary_failback"}

            return {"state": st, "action":"wait_primary_promotion"}

        if st.get("phase") == "rebuilding_secondary_replica":
            if s_db.get("exists"):
                if s_db.get("status") == "available":
                    rds_s.delete_db_instance(
                        DBInstanceIdentifier=SECONDARY_DB_ID,
                        SkipFinalSnapshot=True,
                        DeleteAutomatedBackups=True
                    )
                    return {"state": st, "action":"delete_secondary_writer"}
                return {"state": st, "action":"wait_secondary_deletion"}

            pw = describe_db(rds_p, st.get("primary_writer_id", FAILBACK_DB_ID))
            if not pw.get("exists") or not pw.get("arn"):
                return {"state": st, "action":"wait", "reason":"primary_writer_missing"}

            rds_s.create_db_instance_read_replica(
                DBInstanceIdentifier=SECONDARY_DB_ID,
                SourceDBInstanceIdentifier=pw["arn"],
                DBInstanceClass=SECONDARY_CLASS,
                DBSubnetGroupName=SECONDARY_SUBNET_GROUP,
                VpcSecurityGroupIds=[SECONDARY_DB_SG_ID],
                KmsKeyId=SECONDARY_KMS_KEY,
                PubliclyAccessible=False,
                MultiAZ=False,
                CopyTagsToSnapshot=True
            )

            st["phase"] = "steady"
            put_state(st)
            return {"state": st, "action":"recreate_secondary_replica"}

    return {"state": st, "action":"noop"}
