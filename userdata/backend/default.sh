#!/bin/bash
    set -euxo pipefail

    mkdir -p /var/www/backend
    cat > /var/www/backend/index.html <<'HTML'
    <h1>OK - Backend Instance</h1>
    <p>Esta es una pagina de prueba servida desde las instancias Backends.</p>
    HTML

    nohup python3 -m http.server 8080 --directory /var/www/backend >/var/log/backend-server.log 2>&1 &