#!/bin/bash
# ============================================================================
# ECdialers — Enable WebRTC on ViciDial
# Configures PJSIP + WebSocket for WebRTC agent phones (ECPhone)
# Safe to run on existing installs.
# ============================================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[WebRTC]${NC} $*"; }
warn() { echo -e "${YELLOW}[!!]${NC} $*"; }
die()  { echo -e "${RED}[ERR]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && die "Must run as root"

SERVER_IP=$(hostname -I | awk '{print $1}')
log "Server IP: ${SERVER_IP}"

# ── Backup ────────────────────────────────────────────────────────────────────
TS=$(date +%Y%m%d_%H%M%S)
for f in /etc/asterisk/pjsip.conf /etc/asterisk/http.conf /etc/asterisk/rtp.conf; do
    [ -f "$f" ] && cp -p "$f" "${f}.bak.${TS}"
done
log "Backups created (*.bak.${TS})"

# ── http.conf — enable built-in HTTP + WebSocket ──────────────────────────────
log "Configuring http.conf"
cat > /etc/asterisk/http.conf << EOF
[general]
enabled=yes
bindaddr=0.0.0.0
bindport=8088
tlsenable=yes
tlsbindaddr=0.0.0.0:8089
tlscertfile=/etc/letsencrypt/live/$(hostname)/fullchain.pem
tlsprivatekey=/etc/letsencrypt/live/$(hostname)/privkey.pem
sessionlimit=1000
EOF

# ── rtp.conf ──────────────────────────────────────────────────────────────────
log "Configuring rtp.conf"
cat > /etc/asterisk/rtp.conf << 'EOF'
[general]
rtpstart=10000
rtpend=20000
rtpchecksums=no
dtmftimeout=3000
strictrtp=no
EOF

# ── pjsip.conf — WebRTC transport ─────────────────────────────────────────────
log "Configuring pjsip.conf WebRTC transport"

# Add wss transport if not already present
if ! grep -q "transport-wss" /etc/asterisk/pjsip.conf 2>/dev/null; then
    cat >> /etc/asterisk/pjsip.conf << EOF

; ── ECPhone WebRTC transport ──────────────────────────────────────────────────
[transport-wss]
type=transport
protocol=wss
bind=0.0.0.0

[transport-ws]
type=transport
protocol=ws
bind=0.0.0.0
EOF
    log "WebRTC transports added to pjsip.conf"
else
    warn "transport-wss already exists in pjsip.conf — skipping"
fi

# ── modules.conf — ensure res_http_websocket loaded ───────────────────────────
log "Ensuring WebSocket module is loaded"
sed -i '/noload.*res_http_websocket/d' /etc/asterisk/modules.conf
grep -q "load => res_http_websocket.so" /etc/asterisk/modules.conf || \
    echo "load => res_http_websocket.so" >> /etc/asterisk/modules.conf

# ── ViciDial phone template hint ──────────────────────────────────────────────
log "Updating ViciDial system_settings webphone_url"
HOSTNAME=$(hostname)
mysql -u root asterisk -e "
    UPDATE system_settings SET
        webphone_url='https://${HOSTNAME}/ECPhone/ecphone.php',
        webphone_dialpad='Y',
        webphone_systemkey='webrtc',
        agent_screen_webphone='Y'
    WHERE webphone_url NOT LIKE '%ECPhone%'
    LIMIT 1;" 2>/dev/null || warn "Could not update system_settings — do it manually"

# ── Reload Asterisk ───────────────────────────────────────────────────────────
log "Reloading Asterisk modules"
asterisk -rx "module reload res_http_websocket.so"   2>/dev/null || true
asterisk -rx "module reload res_pjsip.so"            2>/dev/null || true
asterisk -rx "module reload res_pjsip_transport_websocket.so" 2>/dev/null || true
asterisk -rx "http reload"                           2>/dev/null || true

# ── CSF — open WebSocket port ─────────────────────────────────────────────────
if command -v csf >/dev/null 2>&1; then
    log "Opening port 8089 in CSF"
    if ! grep -q "8089" /etc/csf/csf.conf; then
        sed -i 's/TCP_IN = "\(.*\)"/TCP_IN = "\1,8089"/' /etc/csf/csf.conf
        csf -r >/dev/null 2>&1 || true
        log "Port 8089 added to CSF TCP_IN"
    else
        warn "Port 8089 already in CSF — skipping"
    fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
log "WebRTC configuration complete!"
echo ""
echo "  WebSocket URL: wss://${HOSTNAME}:8089/ws"
echo "  ECPhone URL:   https://${HOSTNAME}/ECPhone/ecphone.php"
echo ""
echo "  Next: In ViciDial Admin → Phones, set phone template:"
echo "    protocol       = PJSIP"
echo "    rtcp_mux       = yes"
echo "    ice_support    = yes"
echo "    media_encrypt  = dtls"
echo "    webrtc         = yes"
echo ""
warn "If using self-signed cert, agents must accept it at: https://${HOSTNAME}:8089"
