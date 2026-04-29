#!/bin/bash
# ============================================================================
# ECdialers — Enable WebRTC on ViciDial
# Fully unattended — only asks for domain and email if not provided
#
# Usage:
#   bash vicidial-enable-webrtc.sh                                # interactive
#   bash vicidial-enable-webrtc.sh demo.ecdialers.com             # semi-auto
#   bash vicidial-enable-webrtc.sh demo.ecdialers.com admin@x.com # full auto
# ============================================================================

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'; BOLD='\033[1m'
log()  { echo -e "${GREEN}[WebRTC]${NC} $*"; }
warn() { echo -e "${YELLOW}[!!]${NC} $*"; }
die()  { echo -e "${RED}[ERR]${NC} $*"; exit 1; }
hr()   { echo -e "${GREEN}────────────────────────────────────────────${NC}"; }

[[ $EUID -ne 0 ]] && die "Must run as root"

clear
hr
echo -e "  ${BOLD}ECdialers — WebRTC + SSL Setup${NC}"
hr
echo ""

# ── Gather domain and email ───────────────────────────────────────────────────
DOMAIN="${1:-}"
EMAIL="${2:-}"

if [ -z "$DOMAIN" ]; then
    # Show current domain from system_settings if exists
    CURRENT_DOMAIN=$(mysql -u root asterisk -N -e         "SELECT webphone_url FROM system_settings LIMIT 1;" 2>/dev/null |         grep -oP 'https://\K[^/]+' | head -1)

    if [ -n "$CURRENT_DOMAIN" ]; then
        echo -e "  Current domain: ${YELLOW}${CURRENT_DOMAIN}${NC}"
        echo ""
        echo -e "  ${BOLD}Options:${NC}"
        echo -e "  [1] Keep current domain (${CURRENT_DOMAIN})"
        echo -e "  [2] Change to a new domain"
        echo ""
        read -rp "  Select [1/2]: " DOMAIN_CHOICE
        case "$DOMAIN_CHOICE" in
            2)
                read -rp "  New domain name: " DOMAIN
                ;;
            *)
                DOMAIN="$CURRENT_DOMAIN"
                log "Keeping current domain: ${DOMAIN}"
                ;;
        esac
    else
        read -rp "  Domain name (e.g. demo.ecdialers.com): " DOMAIN
    fi
fi
[ -z "$DOMAIN" ] && die "Domain is required"

if [ -z "$EMAIL" ]; then
    read -rp "  Admin email for SSL cert [admin@ecdialers.com]: " EMAIL
    EMAIL="${EMAIL:-admin@ecdialers.com}"
fi

SERVER_IP=$(hostname -I | awk '{print $1}')
CERT_PATH="/etc/letsencrypt/live/${DOMAIN}"

log "Domain:    ${DOMAIN}"
log "Email:     ${EMAIL}"
log "Server IP: ${SERVER_IP}"
echo ""

# ── Step 1: SSL Certificate ───────────────────────────────────────────────────
hr; log "Step 1/5 — SSL Certificate"

if [ -f "${CERT_PATH}/fullchain.pem" ]; then
    log "SSL cert already exists — skipping certbot"
else
    log "Obtaining SSL certificate for ${DOMAIN}..."

    # Ensure basic HTTP vhost exists for certbot validation
    if ! grep -rq "ServerName ${DOMAIN}" /etc/httpd/conf.d/ 2>/dev/null; then
        cat > /etc/httpd/conf.d/${DOMAIN}.conf << EOF
<VirtualHost *:80>
    ServerName ${DOMAIN}
    DocumentRoot /var/www/html
</VirtualHost>
EOF
        systemctl restart httpd 2>/dev/null || true
    fi

    # Remove any broken SSL vhost before certbot runs
    rm -f /etc/httpd/conf.d/ecdialers-ssl.conf
    systemctl restart httpd 2>/dev/null || true

    # Stop CSF temporarily
    csf -x 2>/dev/null || true

    certbot --apache -d "${DOMAIN}" --non-interactive --agree-tos \
        -m "${EMAIL}" --redirect && \
        log "SSL certificate obtained OK" || \
        die "Certbot failed — check DNS: host ${DOMAIN}"

    # Re-enable CSF
    csf -e 2>/dev/null || true
fi

# Verify cert exists
[ -f "${CERT_PATH}/fullchain.pem" ] || die "SSL cert not found at ${CERT_PATH} — certbot may have failed"

# ── Step 2: Asterisk config files ─────────────────────────────────────────────
hr; log "Step 2/5 — Asterisk config files"

TS=$(date +%Y%m%d_%H%M%S)
for f in /etc/asterisk/pjsip.conf /etc/asterisk/http.conf /etc/asterisk/rtp.conf; do
    [ -f "$f" ] && cp -p "$f" "${f}.bak.${TS}"
done

# http.conf
cat > /etc/asterisk/http.conf << EOF
[general]
enabled=yes
bindaddr=0.0.0.0
bindport=8088
tlsenable=yes
tlsbindaddr=0.0.0.0:8089
tlscertfile=${CERT_PATH}/fullchain.pem
tlsprivatekey=${CERT_PATH}/privkey.pem
sessionlimit=1000
EOF
log "http.conf OK"

# rtp.conf
cat > /etc/asterisk/rtp.conf << EOF
[general]
rtpstart=10000
rtpend=20000
rtpchecksums=no
dtmftimeout=3000
strictrtp=no
icehost=${SERVER_IP}
EOF
log "rtp.conf OK"

# pjsip transports
if ! grep -q "transport-wss" /etc/asterisk/pjsip.conf 2>/dev/null; then
    cat >> /etc/asterisk/pjsip.conf << EOF

; ── ECPhone WebRTC transports ──────────────────────────────────────────────────
[transport-wss]
type=transport
protocol=wss
bind=0.0.0.0
local_net=${SERVER_IP}/255.255.255.0
external_media_address=${SERVER_IP}
external_signaling_address=${SERVER_IP}

[transport-ws]
type=transport
protocol=ws
bind=0.0.0.0

[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0
local_net=${SERVER_IP}/255.255.255.0
external_media_address=${SERVER_IP}
external_signaling_address=${SERVER_IP}
EOF
    log "pjsip WebRTC transports added"
else
    sed -i "s/external_media_address=.*/external_media_address=${SERVER_IP}/" /etc/asterisk/pjsip.conf
    sed -i "s/external_signaling_address=.*/external_signaling_address=${SERVER_IP}/" /etc/asterisk/pjsip.conf
    log "pjsip transports updated"
fi

# modules.conf
sed -i '/noload.*res_http_websocket/d' /etc/asterisk/modules.conf
grep -q "load => res_http_websocket.so" /etc/asterisk/modules.conf || \
    echo "load => res_http_websocket.so" >> /etc/asterisk/modules.conf
log "modules.conf OK"

# ── Step 3: ViciDial DB updates ───────────────────────────────────────────────
hr; log "Step 3/5 — ViciDial database"

# SIP_generic template
mysql -u root asterisk -e "
UPDATE vicidial_conf_templates
SET template_contents='type=friend
host=dynamic
context=default
trustrpid=yes
sendrpid=no
qualify=yes
qualifyfreq=600
transport=ws,wss,udp
encryption=yes
avpf=yes
icesupport=yes
rtcp_mux=yes
directmedia=no
disallow=all
allow=ulaw,opus,vp8,h264
nat=force_rport,comedia
dtlsenable=yes
dtlsverify=no
dtlscertfile=${CERT_PATH}/cert.pem
dtlsprivatekey=${CERT_PATH}/privkey.pem
dtlssetup=actpass'
WHERE template_id='SIP_generic';" 2>/dev/null && \
    log "SIP_generic template updated" || \
    warn "SIP_generic update failed — template may not exist yet"

# phones
mysql -u root asterisk -e "
ALTER TABLE phones MODIFY COLUMN is_webphone ENUM('Y','N','Y_API_LAUNCH') DEFAULT 'Y';
UPDATE phones SET template_id='SIP_generic', is_webphone='Y';" 2>/dev/null && \
    log "Phones updated to WebRTC mode" || \
    warn "Phones update failed"

# system_settings — only update columns that exist
log "Updating system_settings..."
EXISTING_COLS=$(mysql -u root asterisk -N -e \
    "SELECT COLUMN_NAME FROM information_schema.COLUMNS
     WHERE TABLE_SCHEMA='asterisk' AND TABLE_NAME='system_settings';" 2>/dev/null)

build_update() {
    local sets=""
    local col val
    while IFS='=' read -r col val; do
        if echo "$EXISTING_COLS" | grep -qw "$col"; then
            sets="${sets}${col}='${val}',"
        else
            warn "Column '${col}' not found in system_settings — skipping"
        fi
    done
    echo "${sets%,}"
}

UPDATES=$(build_update << EOF
webphone_url=https://${DOMAIN}/ECPhone/ecphone.php
webphone_systemkey=webrtc
webphone_width=260
webphone_height=440
agent_screen_webphone=Y
agent_screen_webphone_layout=css/ecdialers.css
active_voicemail_server=${SERVER_IP}
sounds_web_server=https://${DOMAIN}
EOF
)

if [ -n "$UPDATES" ]; then
    mysql -u root asterisk -e "UPDATE system_settings SET ${UPDATES};" 2>/dev/null && \
        log "system_settings updated" || \
        warn "system_settings update had errors"
fi

# ── Step 4: Apache SSL vhost ──────────────────────────────────────────────────
hr; log "Step 4/5 — Apache SSL vhost"

cat > /etc/httpd/conf.d/ecdialers-ssl.conf << EOF
<VirtualHost *:443>
    ServerName ${DOMAIN}
    DocumentRoot /var/www/html

    SSLEngine on
    SSLCertificateFile      ${CERT_PATH}/fullchain.pem
    SSLCertificateKeyFile   ${CERT_PATH}/privkey.pem

    <Directory /var/www/html>
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog /var/log/httpd/ssl_error.log
    CustomLog /var/log/httpd/ssl_access.log combined
</VirtualHost>
EOF

# Update certbot-generated conf if exists
CERTBOT_CONF="/etc/httpd/conf.d/${DOMAIN}-le-ssl.conf"
[ -f "$CERTBOT_CONF" ] && log "Certbot SSL conf already exists: ${CERTBOT_CONF}"

# Copy cert to Cockpit if available
if [ -d /etc/cockpit/ws-certs.d ]; then
    cp "${CERT_PATH}/fullchain.pem" /etc/cockpit/ws-certs.d/ecdialers.cert 2>/dev/null || true
    cp "${CERT_PATH}/privkey.pem"   /etc/cockpit/ws-certs.d/ecdialers.key  2>/dev/null || true
    systemctl restart cockpit.socket 2>/dev/null || true
    log "Cockpit SSL updated"
fi

systemctl restart httpd && log "Apache restarted OK" || warn "Apache restart failed — check config"

# ── Step 5: Reload Asterisk + CSF ─────────────────────────────────────────────
hr; log "Step 5/5 — Reload Asterisk + CSF"

asterisk -rx "module load res_http_websocket.so"              2>/dev/null || true
asterisk -rx "module load res_pjsip_transport_websocket.so"   2>/dev/null || true
asterisk -rx "module reload res_pjsip.so"                     2>/dev/null || true
log "Asterisk modules loaded"

if command -v csf >/dev/null 2>&1; then
    for port in 8088 8089; do
        grep -q "$port" /etc/csf/csf.conf || \
            sed -i "s/TCP_IN = \"\(.*\)\"/TCP_IN = \"\1,${port}\"/" /etc/csf/csf.conf
    done
    csf -r >/dev/null 2>&1 && log "CSF restarted with WebRTC ports" || warn "CSF restart failed"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
hr
echo -e "  ${BOLD}WebRTC Setup Complete!${NC}"
hr
echo ""
echo -e "  Domain:      ${DOMAIN}"
echo -e "  ECPhone:     https://${DOMAIN}/ECPhone/ecphone.php"
echo -e "  WebSocket:   wss://${DOMAIN}:8089/ws"
echo -e "  Server IP:   ${SERVER_IP}"
echo -e "  SSL Cert:    expires $(openssl x509 -enddate -noout -in ${CERT_PATH}/fullchain.pem | cut -d= -f2)"
echo ""
echo -e "  ${BOLD}Next steps:${NC}"
echo -e "  1. Admin → Phones → verify template = SIP_generic"
echo -e "  2. Admin → System Settings → verify webphone_url"
echo -e "  3. Login as agent → ECPhone should auto-register"
echo ""
