## Tags comunes del proyecto
locals {
  common_tags = {
    Project     = var.project_name
    Environment = terraform.workspace
    ManagedBy   = "Terraform"
  }
}

## Tags para la región Primaria
locals {
  primary_tags = {
    RegionRole = "Primary"
  }
}

## Tags para la región Secundaria
locals {
  secondary_tags = {
    RegionRole = "Secondary"
  }
}

## Selecciona las primeras N(var.az_count) AZs disponibles en la Región Primaria y Secundaria
locals {
  azs_primary   = slice(sort(data.aws_availability_zones.primary.names), 0, var.az_count)
  azs_secondary = slice(sort(data.aws_availability_zones.secondary.names), 0, var.az_count)
}

## recursos de VPC Endpoints para SSM
locals {
  ssm_vpce_services = toset(["ssm", "ec2messages", "ssmmessages"])
}

# Dirección del Resolver de la región primaria y secundaria
locals {
  vpc_resolver_cidr_primary = "${cidrhost(module.vpc_primary.vpc_cidr_block, 2)}/32"
  #vpc_resolver_cidr_secondary = "${cidrhost(module.vpc_secondary.vpc_cidr_block, 2)}/32"
}

# Id de los grupo de seguridad correspondientes al Frontend y Backend de las Regiones Primaria y Secundaria
locals {
  app_instance_sg_primary = {
    frontend = aws_security_group.frontend_sg_primary.id
    backend  = aws_security_group.backend_sg_primary.id
  }
  # Descomentar una vez creado los recursos secundarios
  # app_instance_sg_secondary = {
  #   frontend = aws_security_group.frontend_sg_secondary.id
  #   backend  = aws_security_group.backend_sg_secondary.id
  # }
}

## User Data para instancias Frontend
locals {
  frontend_user_data = base64encode(<<-EOF
    #!/bin/bash
    set -euxo pipefail

    mkdir -p /var/www/html
    cat > /var/www/html/index.html <<'HTML'
    <h1>OK - Frontend Instance</h1>
    <p>Esta es una pagina de prueba servida desde la instancia Frontend.</p>
    HTML

    nohup python3 -m http.server ${var.frontend_port} --directory /var/www/html >/var/log/frontend-server.log 2>&1 &
  EOF
  )
}

## User Data para instancias Backend de la Región Primaria
locals {
  backend_user_data_primary = base64encode(<<-EOF
#!/bin/bash
set -euxo pipefail

# Log completo del user-data para depurar rápido
exec > >(tee /var/log/user-data-backend.log | logger -t user-data-backend -s 2>/dev/console) 2>&1

# (Opcional) desactiva history expansion por si acaso
set +H || true

# Dependencias
yum -y install jq awscli python3 || true

# Cliente PostgreSQL >=10 (Necesario para SCRAM)
amazon-linux-extras install -y postgresql14 || true

export AWS_REGION="${var.primary_region}"
export AWS_DEFAULT_REGION="${var.primary_region}"

# Variables DB (no sensibles)
export DB_HOST="${aws_db_instance.postgresql.address}"
export DB_PORT="${var.db_port}"
export DB_NAME="${var.postgresql_db_name}"
export DB_SECRET_ARN="${aws_db_instance.postgresql.master_user_secret[0].secret_arn}"

mkdir -p /var/www/backend

# Página principal
cat <<'HTML' > /var/www/backend/index.html
<h1>OK - Backend Instance</h1>
<p>Backend arriba.</p>
<p>DB check: <a href="/dbcheck.html">/dbcheck.html</a></p>
HTML

# Estado inicial del dbcheck
cat <<'HTML' > /var/www/backend/dbcheck.html
<h1>DB CHECK: PENDING</h1>
<p>Ejecutando comprobaciones...</p>
HTML

# Script de comprobación DB (delimitador SH al inicio de línea)
cat <<'SH' > /usr/local/bin/dbcheck.sh
#!/bin/bash
set -euo pipefail

LOG="/var/log/dbcheck.log"
OUT="/var/www/backend/dbcheck.html"

echo "==== $(date -Is) dbcheck start ====" >> "$LOG"
echo "REGION=$AWS_REGION - HOST=$DB_HOST - PORT=$DB_PORT - DB=$DB_NAME" >> "$LOG"

DNS_OK="no"
if getent hosts "$DB_HOST" >/dev/null 2>&1; then
  DNS_OK="yes"
fi

# Obtener credenciales desde Secrets Manager
SECRET_JSON="$(aws secretsmanager get-secret-value \
  --region "$AWS_REGION" \
  --secret-id "$DB_SECRET_ARN" \
  --query SecretString \
  --output text 2>>"$LOG")"

DB_USER="$(echo "$SECRET_JSON" | jq -r .username)"
DB_PASS="$(echo "$SECRET_JSON" | jq -r .password)"

# Query real
set +e
RESULT="$(PGPASSWORD="$DB_PASS" psql \
  "host=$DB_HOST port=$DB_PORT dbname=$DB_NAME user=$DB_USER sslmode=require connect_timeout=5" \
  -tAc "select now() as db_time, inet_server_addr() as server_ip, inet_server_port() as server_port, pg_is_in_recovery() as in_recovery;" 2>&1)"
RC=$?
set -e

if [ $RC -eq 0 ]; then
  echo "dbcheck OK: $RESULT" >> "$LOG"
  cat <<HTML > "$OUT"
<h1>DB CHECK: OK</h1>
<p><b>time:</b> $(date -Is)</p>
<p><b>dns_ok:</b> $DNS_OK</p>
<p><b>result:</b> $RESULT</p>
HTML
  exit 0
else
  echo "dbcheck FAIL (rc=$RC): $RESULT" >> "$LOG"
  # Escape mínimo para que no rompa el HTML si hay caracteres raros
  ERR="$(echo "$RESULT" | tail -n 30 | sed 's/&/&amp;/g;s/</&lt;/g;s/>/&gt;/g')"
  cat <<HTML > "$OUT"
<h1>DB CHECK: FAIL</h1>
<p><b>time:</b> $(date -Is)</p>
<p><b>dns_ok:</b> $DNS_OK</p>
<p><b>error (last output):</b></p>
<pre>$ERR</pre>
HTML
  exit 1
fi
SH

chmod +x /usr/local/bin/dbcheck.sh

# Reintentos (RDS puede tardar en estar listo)
for i in $(seq 1 12); do
  if /usr/local/bin/dbcheck.sh; then
    break
  fi
  sleep 10
done || true

# Servidor HTTP backend
nohup python3 -m http.server ${var.backend_port} --directory /var/www/backend >/var/log/backend-server.log 2>&1 &
EOF
  )
}

## User Data para instancias Backend de la Región Secundaria ~!!! MODIFICAR JUNTO BASE DE DATOS !!!~
locals {
  backend_user_data_secondary = base64encode(<<-EOF
#!/bin/bash
set -euxo pipefail

# Log completo del user-data para depurar rápido
exec > >(tee /var/log/user-data-backend.log | logger -t user-data-backend -s 2>/dev/console) 2>&1

# (Opcional) desactiva history expansion por si acaso
set +H || true

# Dependencias
yum -y install jq awscli python3 || true

# Cliente PostgreSQL >=10 (Necesario para SCRAM)
amazon-linux-extras install -y postgresql14 || true

export AWS_REGION="${var.secondary_region}"
export AWS_DEFAULT_REGION="${var.secondary_region}"

# Variables DB (no sensibles)
export DB_HOST="${aws_db_instance.postgresql.address}"
export DB_PORT="${var.db_port}"
export DB_NAME="${var.postgresql_db_name}"
export DB_SECRET_ARN="${aws_db_instance.postgresql.master_user_secret[0].secret_arn}"

mkdir -p /var/www/backend

# Página principal
cat <<'HTML' > /var/www/backend/index.html
<h1>OK - Backend Instance</h1>
<p>Backend arriba.</p>
<p>DB check: <a href="/dbcheck.html">/dbcheck.html</a></p>
HTML

# Estado inicial del dbcheck
cat <<'HTML' > /var/www/backend/dbcheck.html
<h1>DB CHECK: PENDING</h1>
<p>Ejecutando comprobaciones...</p>
HTML

# Script de comprobación DB (delimitador SH al inicio de línea)
cat <<'SH' > /usr/local/bin/dbcheck.sh
#!/bin/bash
set -euo pipefail

LOG="/var/log/dbcheck.log"
OUT="/var/www/backend/dbcheck.html"

echo "==== $(date -Is) dbcheck start ====" >> "$LOG"
echo "REGION=$AWS_REGION - HOST=$DB_HOST - PORT=$DB_PORT - DB=$DB_NAME" >> "$LOG"

DNS_OK="no"
if getent hosts "$DB_HOST" >/dev/null 2>&1; then
  DNS_OK="yes"
fi

# Obtener credenciales desde Secrets Manager
SECRET_JSON="$(aws secretsmanager get-secret-value \
  --region "$AWS_REGION" \
  --secret-id "$DB_SECRET_ARN" \
  --query SecretString \
  --output text 2>>"$LOG")"

DB_USER="$(echo "$SECRET_JSON" | jq -r .username)"
DB_PASS="$(echo "$SECRET_JSON" | jq -r .password)"

# Query real
set +e
RESULT="$(PGPASSWORD="$DB_PASS" psql \
  "host=$DB_HOST port=$DB_PORT dbname=$DB_NAME user=$DB_USER sslmode=require connect_timeout=5" \
  -tAc "select now() as db_time, inet_server_addr() as server_ip, inet_server_port() as server_port, pg_is_in_recovery() as in_recovery;" 2>&1)"
RC=$?
set -e

if [ $RC -eq 0 ]; then
  echo "dbcheck OK: $RESULT" >> "$LOG"
  cat <<HTML > "$OUT"
<h1>DB CHECK: OK</h1>
<p><b>time:</b> $(date -Is)</p>
<p><b>dns_ok:</b> $DNS_OK</p>
<p><b>result:</b> $RESULT</p>
HTML
  exit 0
else
  echo "dbcheck FAIL (rc=$RC): $RESULT" >> "$LOG"
  # Escape mínimo para que no rompa el HTML si hay caracteres raros
  ERR="$(echo "$RESULT" | tail -n 30 | sed 's/&/&amp;/g;s/</&lt;/g;s/>/&gt;/g')"
  cat <<HTML > "$OUT"
<h1>DB CHECK: FAIL</h1>
<p><b>time:</b> $(date -Is)</p>
<p><b>dns_ok:</b> $DNS_OK</p>
<p><b>error (last output):</b></p>
<pre>$ERR</pre>
HTML
  exit 1
fi
SH

chmod +x /usr/local/bin/dbcheck.sh

# Reintentos (RDS puede tardar en estar listo)
for i in $(seq 1 12); do
  if /usr/local/bin/dbcheck.sh; then
    break
  fi
  sleep 10
done || true

# Servidor HTTP backend
nohup python3 -m http.server ${var.backend_port} --directory /var/www/backend >/var/log/backend-server.log 2>&1 &
EOF
  )
}
