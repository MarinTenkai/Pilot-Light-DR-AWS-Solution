 #!/bin/bash
    set -euxo pipefail

    mkdir -p /var/www/html
    cat > /var/www/html/index.html <<'HTML'
    <h1>OK - Frontend Instance</h1>
    <p>Esta es una pagina de prueba servida desde las instancias Frontends.</p>
    HTML

    nohup python3 -m http.server 80 --directory /var/www/html >/var/log/frontend-server.log 2>&1 &