#!/bin/bash
# ============================================================================
# ECdialers -- SSL Certificate Renewal Helper
# Detiene CSF temporalmente, renueva certbot, reinicia CSF
# ============================================================================
# Uso:
#   bash /usr/src/ecdialers-install/certbot.sh
#
# Para renovacion automatica ya esta en el crontab:
#   @monthly certbot renew --quiet
# ============================================================================

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[certbot]${NC} $*"; }
warn() { echo -e "${YELLOW}[!!]${NC} $*"; }
die()  { echo -e "${RED}[ERR]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && die "Must run as root"

# Detectar dominio actual del certificado
DOMAIN=$(basename /etc/letsencrypt/renewal/*.conf 2>/dev/null | sed 's/\.conf$//' | head -1)
[ -z "$DOMAIN" ] && die "No se encontro certificado en /etc/letsencrypt/renewal/"
log "Dominio: ${DOMAIN}"

# Parar CSF temporalmente para liberar puerto 80
log "Deteniendo CSF temporalmente..."
csf -x 2>/dev/null || warn "CSF no disponible -- continuando"

# Mover configs SSL que puedan interferir
if [ -f /etc/httpd/conf.d/viciportal-ssl.conf ]; then
    mv /etc/httpd/conf.d/viciportal-ssl.conf /etc/httpd/conf.d/viciportal-ssl.conf.bak
fi

# Renovar certificado
log "Renovando certificado..."
certbot renew --quiet || {
    warn "certbot renew fallo -- intentando forzar renovacion"
    certbot certonly --apache -d "${DOMAIN}" --non-interactive --agree-tos \
        -m "admin@ecdialers.com" --force-renewal
}

# Restaurar config SSL
if [ -f /etc/httpd/conf.d/viciportal-ssl.conf.bak ]; then
    mv /etc/httpd/conf.d/viciportal-ssl.conf.bak /etc/httpd/conf.d/viciportal-ssl.conf
fi

# Copiar certs a Cockpit si existe
CERT_PATH="/etc/letsencrypt/live/${DOMAIN}"
if [ -d "$CERT_PATH" ] && [ -d /etc/cockpit/ws-certs.d ]; then
    cp "${CERT_PATH}/fullchain.pem" /etc/cockpit/ws-certs.d/ecdialers.cert
    cp "${CERT_PATH}/privkey.pem"   /etc/cockpit/ws-certs.d/ecdialers.key
    systemctl restart cockpit.socket 2>/dev/null || true
    log "Certificado actualizado en Cockpit"
fi

# Reiniciar Apache
systemctl reload httpd && log "Apache recargado OK" || warn "Apache reload fallo"

# Reactivar CSF
log "Reactivando CSF..."
csf -e 2>/dev/null || warn "CSF reactivacion fallo -- revisar: csf -e"

log "Renovacion completada para: ${DOMAIN}"
log "Expira: $(openssl x509 -enddate -noout -in ${CERT_PATH}/fullchain.pem 2>/dev/null | cut -d= -f2)"
