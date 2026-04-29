#!/bin/bash
# ============================================================================
# ECdialers — Enable WebRTC on ViciDial
# Configures PJSIP + WebSocket + SIP template + phones for ECPhone
# Safe to run on existing installs and when changing domains.
#
# Usage:
#   bash vicidial-enable-webrtc.sh                     # auto-detect domain
#   bash vicidial-enable-webrtc.sh demo.ecdialers.com  # specify domain
# ============================================================================

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'; BOLD='\033[1m'
log()  { echo -e "${GREEN}[WebRTC]${NC} $*"; }
warn() { echo -e "${YELLOW}[!!]${NC} $*"; }
die()  { echo -e "${RED}[ERR]${NC} $*"; exit 1; }
hr()   { echo -e "${GREEN}────────────────────────────────────────────${NC}"; }

[[ $EUID -ne 0 ]] && die "Must run as root"

# ── Domain / IP resolution ────────────────────────────────────────────────────
DOMAIN="${1:-$(hostname -f)}"
SERVER_IP=$(hostname -I | awk '{print $1}')
CERT_PATH="/etc/letsencrypt/live/${DOMAIN}"

# Fallback: search for any existing cert
if [ ! -d "$CERT_PATH" ]; then
    FOUND_CERT=$(ls /etc/letsencrypt/live/ 2>/dev/null | grep -v README | head -1)
    if [ -n "$FOUND_CERT" ]; then
        warn "Cert for ${DOMAIN} not found — using ${FOUND_CERT}"
        CERT_PATH="/etc/letsencrypt/live/${FOUND_CERT}"
        DOMAIN="${FOUND_CERT}"
    else
        warn "No SSL cert found in /etc/letsencrypt/live/"
        warn "WebRTC TLS will not work until SSL is configured"
        warn "Run: bash /usr/src/ecdialers-install/certbot.sh"
        CERT_PATH="/etc/letsencrypt/live/${DOMAIN}"
    fi
fi

log "Domain:    ${DOMAIN}"
log "Server IP: ${SERVER_IP}"
log "Cert path: ${CERT_PATH}"
hr

# ── Backup ────────────────────────────────────────────────────────────────────
TS=$(date +%Y%m%d_%H%M%S)
for f in /etc/asterisk/pjsip.conf /etc/asterisk/http.conf /etc/asterisk/rtp.conf; do
    [ -f "$f" ] && cp -p "$f" "${f}.bak.${TS}"
done
log "Backups created (*.bak.${TS})"

# ── http.conf ─────────────────────────────────────────────────────────────────
log "Configuring http.conf"
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
log "http.conf written with cert: ${CERT_PATH}"

# ── rtp.conf ──────────────────────────────────────────────────────────────────
log "Configuring rtp.conf"
cat > /etc/asterisk/rtp.conf << EOF
[general]
rtpstart=10000
rtpend=20000
rtpchecksums=no
dtmftimeout=3000
strictrtp=no
icehost=${SERVER_IP}
EOF
log "rtp.conf written with icehost=${SERVER_IP}"

# ── pjsip.conf — WebRTC transports ───────────────────────────────────────────
log "Configuring pjsip.conf WebRTC transports"

if ! grep -q "transport-wss" /etc/asterisk/pjsip.conf 2>/dev/null; then
    cat >> /etc/asterisk/pjsip.conf << EOF

; ── ECPhone WebRTC transports ─────────────────────────────────────────────────
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
    log "WebRTC transports added to pjsip.conf"
else
    warn "transport-wss already exists — updating external addresses"
    sed -i "s/external_media_address=.*/external_media_address=${SERVER_IP}/" /etc/asterisk/pjsip.conf
    sed -i "s/external_signaling_address=.*/external_signaling_address=${SERVER_IP}/" /etc/asterisk/pjsip.conf
fi

# ── modules.conf ──────────────────────────────────────────────────────────────
log "Ensuring WebSocket modules are loaded"
sed -i '/noload.*res_http_websocket/d' /etc/asterisk/modules.conf
grep -q "load => res_http_websocket.so" /etc/asterisk/modules.conf || \
    echo "load => res_http_websocket.so" >> /etc/asterisk/modules.conf

# ── vicidial_conf_templates — SIP_generic WebRTC ─────────────────────────────
log "Updating SIP_generic phone template for WebRTC"
mysql -u root asterisk << EOF
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
WHERE template_id='SIP_generic';
EOF
log "SIP_generic template updated with WebRTC params + DTLS cert paths"

# ── phones — set WebRTC defaults ──────────────────────────────────────────────
log "Setting phones to WebRTC mode"
mysql -u root asterisk << 'EOF'
ALTER TABLE phones MODIFY COLUMN is_webphone ENUM('Y','N','Y_API_LAUNCH') DEFAULT 'Y';
UPDATE phones SET template_id='SIP_generic', is_webphone='Y'
WHERE template_id NOT IN ('custom') OR template_id IS NULL;
EOF
log "All phones updated to SIP_generic WebRTC template"

# ── system_settings — ALL webphone fields ─────────────────────────────────────
log "Updating system_settings webphone fields"
mysql -u root asterisk << EOF
UPDATE system_settings SET
    webphone_url='https://${DOMAIN}/ECPhone/ecphone.php',
    webphone_dialpad='Y',
    webphone_systemkey='webrtc',
    webphone_width='260',
    webphone_height='440',
    agent_screen_webphone='Y',
    agent_screen_webphone_layout='css/ecdialers.css',
    active_voicemail_server='${SERVER_IP}',
    sounds_web_server='https://${DOMAIN}';
EOF
log "system_settings updated for domain: ${DOMAIN}"

# ── Apache SSL vhost ──────────────────────────────────────────────────────────
log "Configuring Apache SSL vhost"
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

    # WebRTC WebSocket proxy
    ProxyPass /ws ws://127.0.0.1:8088/ws
    ProxyPassReverse /ws ws://127.0.0.1:8088/ws

    ErrorLog /var/log/httpd/ssl_error.log
    CustomLog /var/log/httpd/ssl_access.log combined
</VirtualHost>

<VirtualHost *:80>
    ServerName ${DOMAIN}
    RewriteEngine On
    RewriteRule ^(.*)$ https://%{HTTP_HOST}$1 [R=301,L]
</VirtualHost>
EOF
log "Apache SSL vhost written: /etc/httpd/conf.d/ecdialers-ssl.conf"

# ── Reload services ───────────────────────────────────────────────────────────
log "Reloading services"
systemctl reload httpd 2>/dev/null && log "Apache reloaded OK" || warn "Apache reload failed"

asterisk -rx "module reload res_http_websocket.so"              2>/dev/null || true
asterisk -rx "module reload res_pjsip.so"                       2>/dev/null || true
asterisk -rx "module reload res_pjsip_transport_websocket.so"   2>/dev/null || true
asterisk -rx "http reload"                                      2>/dev/null || true
log "Asterisk modules reloaded"

# ── CSF — open WebSocket ports ────────────────────────────────────────────────
if command -v csf >/dev/null 2>&1; then
    log "Opening WebRTC ports in CSF"
    for port in 8088 8089; do
        if ! grep -q "$port" /etc/csf/csf.conf; then
            sed -i "s/TCP_IN = \"\(.*\)\"/TCP_IN = \"\1,${port}\"/" /etc/csf/csf.conf
            log "Port ${port} added to CSF TCP_IN"
        else
            warn "Port ${port} already in CSF"
        fi
    done
    csf -r >/dev/null 2>&1 && log "CSF restarted" || warn "CSF restart failed"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
hr
echo -e "  ${BOLD}WebRTC Configuration Complete!${NC}"
hr
echo ""
echo -e "  Domain:        ${DOMAIN}"
echo -e "  ECPhone URL:   https://${DOMAIN}/ECPhone/ecphone.php"
echo -e "  WebSocket:     wss://${DOMAIN}:8089/ws"
echo -e "  Server IP:     ${SERVER_IP}"
echo ""
echo -e "  ${BOLD}ViciDial Phone Template (SIP_generic):${NC}"
echo -e "  transport=ws,wss,udp  |  dtls=yes  |  avpf=yes  |  icesupport=yes"
echo ""
echo -e "  ${BOLD}Next steps in ViciDial Admin:${NC}"
echo -e "  1. Admin → Phones → verify template_id = SIP_generic"
echo -e "  2. Admin → System Settings → verify webphone_url"
echo -e "  3. Test: login agent → phone should auto-register via WebRTC"
echo ""
if [ ! -f "${CERT_PATH}/fullchain.pem" ]; then
    warn "SSL cert not found at ${CERT_PATH}"
    warn "Run: bash /usr/src/ecdialers-install/certbot.sh"
fi
