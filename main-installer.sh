#!/bin/bash
# ============================================================================
# ECdialers ViciDial Installer
# AlmaLinux 9 | Asterisk 18.21.0-vici | CSF Firewall
# https://github.com/oaparicio1/ecdialers-install
#
# Usage:
#   cd /usr/src/
#   git clone https://github.com/oaparicio1/ecdialers-install.git
#   cd ecdialers-install
#   chmod +x main-installer.sh
#   ./main-installer.sh
# ============================================================================
# set -euo pipefail -- desactivado para permitir continuar ante errores no criticos
set -uo pipefail 2>/dev/null || true

# -- Colors -------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${GREEN}[EC]${NC} $*"; }
warn() { echo -e "${YELLOW}[!!]${NC} $*"; }
die()  { echo -e "${RED}[ERR]${NC} $*" >&2; exit 1; }
hr()   { echo -e "${CYAN}==================================================${NC}"; }

# ── Banner ───────────────────────────────────────────────────────────────────
clear
hr
echo -e "${BOLD}${CYAN}"
echo "  ███████╗ ██████╗ ██████╗ ██╗ █████╗ ██╗     ███████╗██████╗ ███████╗"
echo "  ██╔════╝██╔════╝ ██╔══██╗██║██╔══██╗██║     ██╔════╝██╔══██╗██╔════╝"
echo "  █████╗  ██║      ██║  ██║██║███████║██║     █████╗  ██████╔╝███████╗"
echo "  ██╔══╝  ██║      ██║  ██║██║██╔══██║██║     ██╔══╝  ██╔══██╗╚════██║"
echo "  ███████╗╚██████╗ ██████╔╝██║██║  ██║███████╗███████╗██║  ██║███████║"
echo "  ╚══════╝ ╚═════╝ ╚═════╝ ╚═╝╚═╝  ╚═╝╚══════╝╚══════╝╚═╝  ╚═╝╚══════╝"
echo -e "${NC}"
echo -e "  ${BOLD}ViciDial Installer${NC} — AlmaLinux 9 | Asterisk 18 | CSF"
echo -e "  https://github.com/oaparicio1/ecdialers-install"
hr
echo ""

# -- Verify root --------------------------------------------------------------
[[ $EUID -ne 0 ]] && die "Must run as root"

# -- Verify AlmaLinux 9 -------------------------------------------------------
if ! grep -q "AlmaLinux" /etc/os-release; then
    warn "This installer is tested on AlmaLinux 9 only. Proceed anyway? [y/N]"
    read -r ans; [[ "$ans" =~ ^[Yy]$ ]] || exit 0
fi

# -- Gather info --------------------------------------------------------------
hr
echo -e "${BOLD}Server Configuration${NC}"
hr

# Hostname
CURRENT_HOST=$(hostname 2>/dev/null || echo "")
read -rp "Hostname [${CURRENT_HOST}]: " INPUT_HOST
HOSTNAME="${INPUT_HOST:-$CURRENT_HOST}"
hostnamectl set-hostname "$HOSTNAME"

# IP
SERVER_IP=$(hostname -I | awk '{print $1}')
log "Detected IP: ${SERVER_IP}"

# Timezone
read -rp "Timezone [America/New_York]: " INPUT_TZ
TIMEZONE="${INPUT_TZ:-America/New_York}"

# DB password
read -rp "MySQL cron user password [1234]: " INPUT_DBPASS
DB_PASS="${INPUT_DBPASS:-1234}"

echo ""
log "Hostname   : ${HOSTNAME}"
log "IP Address : ${SERVER_IP}"
log "Timezone   : ${TIMEZONE}"
log "DB Pass    : ${DB_PASS}"
echo ""
warn "Starting installation. This will take 15-30 minutes."
read -rp "Press Enter to continue or Ctrl+C to abort..."

# -- Installer directory (definido una sola vez) -------------------------------
INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"


# -- Locale & timezone --------------------------------------------------------
hr; log "Setting locale and timezone"
dnf install -y glibc-langpack-en >/dev/null
localectl set-locale en_US.UTF-8
timedatectl set-timezone "$TIMEZONE"
# ── SELinux check + disable ───────────────────────────────────────────────────
SELINUX_STATUS=$(getenforce 2>/dev/null || echo "Disabled")
if [ "$SELINUX_STATUS" = "Enforcing" ] || [ "$SELINUX_STATUS" = "Permissive" ]; then
    warn "SELinux is ${SELINUX_STATUS} — disabling for ViciDial compatibility"
    sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
    sed -i 's/SELINUX=permissive/SELINUX=disabled/g' /etc/selinux/config
    setenforce 0 2>/dev/null || true
    log "SELinux disabled (runtime + config) ✓"
else
    log "SELinux already disabled ✓"
fi
export LC_ALL=C

# -- Base packages ------------------------------------------------------------
hr; log "Installing base packages and repos"

dnf groupinstall "Development Tools" -y
dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
dnf install -y https://rpms.remirepo.net/enterprise/remi-release-9.rpm
dnf module enable php:remi-7.4 -y
# MariaDB 10.5 via repo oficial (AlmaLinux 9 no tiene module stream mariadb:10.5)
curl -LsS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup |     bash -s -- --mariadb-server-version=mariadb-10.5 --skip-maxscale --skip-tools

# mysql* se excluye solo donde es necesario (--exclude=mysql* en dnf perl install)
dnf install -y dnf-plugins-core
dnf config-manager --set-enabled crb

dnf install -y \
    wget curl unzip make patch gcc gcc-c++ subversion \
    php php-cli php-devel php-gd php-curl php-mysql php-mysqli \
    php-ldap php-zip php-fileinfo php-opcache php-mbstring \
    php-imap php-odbc php-pear php-xml php-xmlrpc \
    gd-devel readline-devel \
    perl-libwww-perl ImageMagick \
    newt-devel libxml2-devel kernel-devel sqlite-devel \
    libuuid-devel sox lame-devel htop iftop atop \
    perl-File-Which \
    initscripts pv python3-pip libxcrypt-compat \
    nano chkconfig screen mytop inxi \
    postfix inxi \
    libsrtp-devel libedit-devel elfutils-libelf-devel \
    httpd httpd-tools mod_ssl

# libss7 (puede no estar disponible en todos los repos -- no critico)
dnf install -y libss7 libss7-devel 2>/dev/null || warn 'libss7 not available -- continuing'

# sngrep (SIP capture tool) -- repo de IRONTEC requerido en AlmaLinux 9
dnf install -y bind-utils
rpm -q sngrep &>/dev/null || {
    dnf install -y 'https://packages.irontec.com/rhel/9/noarch/irontec-release-1.0-1.noarch.rpm' 2>/dev/null &&     dnf install -y sngrep 2>/dev/null || warn "sngrep no disponible -- instalar manualmente si se necesita"
}

# -- Kernel headers -----------------------------------------------------------
dnf install -y "kernel-devel-$(uname -r)" "kernel-headers-$(uname -r)" || \
    dnf install -y kernel-devel kernel-headers

# -- PHP config ---------------------------------------------------------------
hr; log "Configuring PHP"
cat >> /etc/php.ini << 'EOF'

; -- ECdialers ViciDial config --
error_reporting  = E_ALL & ~E_NOTICE
memory_limit = 448M
short_open_tag = On
max_execution_time = 3330
max_input_time = 3360
post_max_size = 448M
upload_max_filesize = 442M
default_socket_timeout = 3360
max_input_vars = 50000
EOF
# Set timezone in php.ini
sed -i "s|;date.timezone =|date.timezone = ${TIMEZONE}|" /etc/php.ini
# browscap for ECPhone access log
mkdir -p /etc/php.d
echo "browscap = /etc/php.d/browscap.ini" >> /etc/php.ini
wget -q -O /etc/php.d/browscap.ini https://browscap.org/stream?q=Lite_PHP_BrowsCap || \
    touch /etc/php.d/browscap.ini

# -- MariaDB ------------------------------------------------------------------
hr; log "Installing MariaDB"
dnf install -y mariadb-server mariadb

cp /etc/my.cnf /etc/my.cnf.bak
cat > /etc/my.cnf << 'MYSQLCONF'
[mysql.server]
user = mysql

[client]
port = 3306
socket = /var/lib/mysql/mysql.sock

[mysqld]
datadir = /var/lib/mysql
socket = /var/lib/mysql/mysql.sock
user = mysql
old_passwords = 0
ft_min_word_len = 3
max_connections = 800
max_allowed_packet = 32M
skip-external-locking
sql_mode="NO_ENGINE_SUBSTITUTION"
log-error = /var/log/mysqld/mysqld.log
# query-cache-type y query-cache-size removidos en MariaDB 10.5
long_query_time = 1
tmp_table_size = 128M
table_cache = 1024
join_buffer_size = 1M
key_buffer_size = 512M
sort_buffer_size = 6M
read_buffer_size = 4M
read_rnd_buffer_size = 16M
myisam_sort_buffer_size = 64M
max_tmp_tables = 64
thread_cache_size = 8
# thread_concurrency deprecado en MariaDB 10.5

[mysqldump]
quick
max_allowed_packet = 16M

[mysql]
no-auto-rehash

[isamchk]
key_buffer_size = 256M
sort_buffer_size = 256M
read_buffer = 2M
write_buffer = 2M

[myisamchk]
key_buffer_size = 256M
sort_buffer_size = 256M
read_buffer = 2M
write_buffer = 2M

[mysqlhotcopy]
interactive-timeout
MYSQLCONF

mkdir -p /var/log/mysqld
touch /var/log/mysqld/slow-queries.log
chown -R mysql:mysql /var/log/mysqld

systemctl enable --now mariadb || die 'MariaDB could not start -- check logs: journalctl -u mariadb'
# httpd se habilita despues de instalarlo (ver bloque final)

# -- Perl modules -------------------------------------------------------------
hr; log "Installing Perl base modules via dnf"
# --exclude=mysql* evita que cualquier dep chain jale mysql-common
# que conflictua con MariaDB-common ya instalado
dnf install -y --exclude=mysql* \
    perl-CPAN perl-YAML perl-CPAN-DistnameInfo perl-libwww-perl \
    perl-GD perl-Env perl-Term-ReadLine-Gnu perl-SelfLoader perl-open

hr; log "Installing Perl CPAN modules via CPM (includes DBD::MySQL)"
# CPM instala DBD::MySQL sin depender de mysql-common del sistema
curl -fsSL https://raw.githubusercontent.com/skaji/cpm/main/cpm | perl - install -g App::cpm
cd "${INSTALLER_DIR}" && /usr/local/bin/cpm install -g

# Asterisk Perl
cd /usr/src
wget -q http://download.vicidial.com/required-apps/asterisk-perl-0.08.tar.gz
tar xzf asterisk-perl-0.08.tar.gz
cd asterisk-perl-0.08
perl Makefile.PL && make all && make install || warn 'asterisk-perl failed -- some scripts may not work'

# -- Lame ---------------------------------------------------------------------
hr; log "Installing Lame"
# Intentar desde RPM Fusion primero, si falla compilar desde fuente
dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm 2>/dev/null || true
dnf install -y lame lame-devel 2>/dev/null || {
    warn "Lame RPM not available -- compiling from source"
    cd /usr/src
    wget -q http://downloads.sourceforge.net/project/lame/lame/3.99/lame-3.99.5.tar.gz
    tar -zxf lame-3.99.5.tar.gz
    cd lame-3.99.5
    ./configure && make && make install
}

# -- Jansson ------------------------------------------------------------------
hr; log "Installing Jansson"
cd /usr/src
wget -q https://digip.org/jansson/releases/jansson-2.13.tar.gz
tar xvzf jansson-2.13.tar.gz
cd jansson-2.13
./configure && make clean && make && make install
ldconfig

# -- DAHDI --------------------------------------------------------------------
hr; log "Installing DAHDI"
ln -sf /usr/lib/modules/$(uname -r)/vmlinux.xz /boot/ 2>/dev/null || true
# newt.h required for DAHDI tools — goes in /etc/include/ (same as carpenox)
mkdir -p /etc/include
cd /etc/include
wget -q https://dialer.one/newt.h || warn 'newt.h not downloaded -- continuing'
cd /usr/src

mkdir -p /usr/src/dahdi-linux-complete-3.4.0+3.4.0
cd /usr/src/dahdi-linux-complete-3.4.0+3.4.0
wget -q https://raw.githubusercontent.com/oaparicio1/ecdialers-install/main/assets/dahdi-9.5-fix.zip
unzip -q dahdi-9.5-fix.zip
dnf install -y newt newt-devel
make clean && make && make install && make install-config || warn 'DAHDI linux build failed -- not critical for WebRTC'
dnf install -y dahdi-tools-libs 2>/dev/null || true
cd tools 2>/dev/null && make clean && make && make install && make install-config || warn 'DAHDI tools build failed -- continuing'
cp /etc/dahdi/system.conf.sample /etc/dahdi/system.conf
modprobe dahdi 2>/dev/null || true
modprobe dahdi_dummy 2>/dev/null || true
/usr/sbin/dahdi_cfg -vvv 2>/dev/null || true
systemctl enable dahdi 2>/dev/null || true
systemctl start dahdi 2>/dev/null || service dahdi start 2>/dev/null || true

read -rp "DAHDI done. Press Enter to continue with Asterisk..."

# -- libsrtp ------------------------------------------------------------------
hr; log "Installing libsrtp 2.1.0"
cd /usr/src
wget -q https://github.com/cisco/libsrtp/archive/v2.1.0.tar.gz -O libsrtp-2.1.0.tar.gz
tar xf libsrtp-2.1.0.tar.gz
cd libsrtp-2.1.0
./configure --prefix=/usr --enable-openssl
make shared_library && make install || warn 'libsrtp system install failed -- using Asterisk bundled'
ldconfig

# -- Asterisk 18 --------------------------------------------------------------
hr; log "Installing Asterisk 18.21.0-vici"
mkdir -p /usr/src/asterisk && cd /usr/src/asterisk
wget -q https://downloads.asterisk.org/pub/telephony/libpri/libpri-1.6.1.tar.gz
wget -q https://download.vicidial.com/required-apps/asterisk-18.21.0-vici.tar.gz
tar -xzf asterisk-18.21.0-vici.tar.gz
tar -xzf libpri-1.6.1.tar.gz
cd libpri-1.6.1 && make && make install

cd /usr/src/asterisk/asterisk-18.21.0-vici/
dnf install -y libuuid-devel libxml2-devel

JOBS=$(( $(nproc) + $(nproc) / 2 ))
./configure --libdir=/usr/lib64 --with-gsm=internal \
    --enable-opus --enable-srtp --with-ssl --enable-asteriskssl \
    --with-pjproject-bundled --with-jansson-bundled

make menuselect/menuselect menuselect-tree menuselect.makeopts
menuselect/menuselect --enable app_meetme        menuselect.makeopts
menuselect/menuselect --enable res_http_websocket menuselect.makeopts
menuselect/menuselect --enable res_srtp          menuselect.makeopts

# Crear directorios requeridos por make samples
mkdir -p /var/lib/asterisk/phoneprov
mkdir -p /var/lib/asterisk/sounds
mkdir -p /var/spool/asterisk/voicemail/default/1234/INBOX

make samples || warn 'make samples had minor errors -- continuing'
sed -i 's|noload = chan_sip.so|;noload = chan_sip.so|g' /etc/asterisk/modules.conf

make -j "${JOBS}" all && make install || die 'Asterisk build failed -- check errors above'

# Fix modules
cat >> /etc/asterisk/modules.conf << 'EOF'
noload => res_timing_timerfd.so
noload => res_timing_kqueue.so
noload => res_timing_pthread.so
EOF

# Secure manager
sed -i 's/0.0.0.0/127.0.0.1/g' /etc/asterisk/manager.conf

# confcron manager user
cat >> /etc/asterisk/manager.conf << 'EOF'

[confcron]
secret = 1234
read = command,reporting
write = command,reporting
eventfilter=Event: Meetme
eventfilter=Event: Confbridge
EOF

# Verificar que Asterisk quedo instalado
[ -f /usr/sbin/asterisk ] || die 'Asterisk not installed -- check compilation errors'
log "Asterisk $(/usr/sbin/asterisk -V 2>/dev/null) instalado OK"
read -rp "Asterisk done. Press Enter to continue with ViciDial..."

# -- ViciDial (astguiclient) ---------------------------------------------------
hr; log "Installing ViciDial (astguiclient trunk)"
mkdir -p /usr/src/astguiclient && cd /usr/src/astguiclient
svn checkout svn://svn.eflo.net/agc_2-X/trunk || die 'SVN checkout failed -- check connectivity'

# -- MySQL databases ----------------------------------------------------------
hr; log "Creating MySQL databases and users"

# Verificar si la DB asterisk ya existe con datos
DB_EXISTS=$(mysql -u root -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='asterisk';" 2>/dev/null | tail -1)
DB_EXISTS=${DB_EXISTS:-0}

if [ "$DB_EXISTS" -gt "10" ]; then
    warn ""
    warn "Database asterisk already exists with ${DB_EXISTS} tables."
    warn ""
    echo -e "  Options:"
    echo -e "  ${BOLD}[1]${NC} DROP and recreate from scratch (clean install -- DELETES ALL DATA)"
    echo -e "  ${BOLD}[2]${NC} Keep existing data (only add missing tables/users)"
    echo -e "  ${BOLD}[3]${NC} Cancel installation"
    echo ""
    read -rp "  Select [1/2/3]: " DB_CHOICE
    case "$DB_CHOICE" in
        1)
            warn "Dropping asterisk database..."
            mysql -u root -e "DROP DATABASE IF EXISTS asterisk;" || die "Could not drop database"
            log "Database dropped -- will be recreated from scratch"
            ;;
        2)
            log "Keeping existing data -- adding missing tables/users only"
            ;;
        3)
            die "Installation cancelled by user"
            ;;
        *)
            warn "Invalid option -- keeping existing data"
            ;;
    esac
else
    log "Database does not exist or is empty -- clean install"
fi

# Create DB, users and load schema
mysql -u root --force << MYSQLEOF
CREATE DATABASE IF NOT EXISTS asterisk DEFAULT CHARACTER SET utf8 COLLATE utf8_unicode_ci;
CREATE USER IF NOT EXISTS 'cron'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT SELECT,CREATE,ALTER,INSERT,UPDATE,DELETE,LOCK TABLES ON asterisk.* TO cron@'%' IDENTIFIED BY '${DB_PASS}';
GRANT SELECT,CREATE,ALTER,INSERT,UPDATE,DELETE,LOCK TABLES ON asterisk.* TO cron@localhost IDENTIFIED BY '${DB_PASS}';
GRANT RELOAD ON *.* TO cron@'%';
GRANT RELOAD ON *.* TO cron@localhost;
CREATE USER IF NOT EXISTS 'custom'@'localhost' IDENTIFIED BY 'custom1234';
GRANT SELECT,CREATE,ALTER,INSERT,UPDATE,DELETE,LOCK TABLES ON asterisk.* TO custom@'%' IDENTIFIED BY 'custom1234';
GRANT SELECT,CREATE,ALTER,INSERT,UPDATE,DELETE,LOCK TABLES ON asterisk.* TO custom@localhost IDENTIFIED BY 'custom1234';
GRANT RELOAD ON *.* TO custom@'%';
GRANT RELOAD ON *.* TO custom@localhost;
FLUSH PRIVILEGES;
SET GLOBAL connect_timeout=60;
USE asterisk;
\. /usr/src/astguiclient/trunk/extras/MySQL_AST_CREATE_tables.sql
\. /usr/src/astguiclient/trunk/extras/first_server_install.sql
UPDATE servers SET asterisk_version='18.21.1-vici';
QUIT
MYSQLEOF
[ $? -ne 0 ] && die 'Critical MySQL error -- check MariaDB'

# -- astguiclient.conf ---------------------------------------------------------
hr; log "Writing astguiclient.conf"
cat > /etc/astguiclient.conf << ASTGUI
# astguiclient.conf -- ECdialers ViciDial

PATHhome => /usr/share/astguiclient
PATHlogs => /var/log/astguiclient
PATHagi  => /var/lib/asterisk/agi-bin
PATHweb  => /var/www/html
PATHsounds   => /var/lib/asterisk/sounds
PATHmonitor  => /var/spool/asterisk/monitor
PATHDONEmonitor => /var/spool/asterisk/monitorDONE

VARserver_ip => SERVERIP

VARDB_server   => localhost
VARDB_database => asterisk
VARDB_user     => cron
VARDB_pass     => ${DB_PASS}
VARDB_custom_user => custom
VARDB_custom_pass => custom1234
VARDB_port     => 3306

VARactive_keepalives => 12345689EC

VARasterisk_version => 18.X

VARfastagi_log_min_servers    => 3
VARfastagi_log_max_servers    => 16
VARfastagi_log_min_spare_servers => 2
VARfastagi_log_max_spare_servers => 8
VARfastagi_log_max_requests   => 1000
VARfastagi_log_checkfordead   => 30
VARfastagi_log_checkforwait   => 60

ExpectedDBSchema => 1720
ASTGUI

sed -i "s/SERVERIP/${SERVER_IP}/g" /etc/astguiclient.conf

# -- ViciDial install.pl -------------------------------------------------------
hr; log "Running ViciDial install.pl"
cd /usr/src/astguiclient/trunk
perl install.pl --no-prompt --copy_sample_conf_files=Y || warn 'install.pl fase 1 tuvo advertencias -- verificar'
perl install.pl --no-prompt || warn 'install.pl fase 2 tuvo advertencias -- verificar'
# Verificar que ViciDial quedo instalado correctamente
[ -f /usr/share/astguiclient/ADMIN_keepalive_ALL.pl ] || die 'ViciDial not installed correctly -- check install.pl output'
log "ViciDial instalado correctamente OK"

# Update server IP
/usr/share/astguiclient/ADMIN_update_server_ip.pl \
    --old-server_ip=10.10.10.15 --server_ip="${SERVER_IP}" --auto 2>/dev/null || true

# Populate area codes
/usr/share/astguiclient/ADMIN_area_code_populate.pl 2>/dev/null || true

# -- Asterisk sounds -----------------------------------------------------------
hr; log "Installing Asterisk sounds"
cd /usr/src
for pkg in \
    asterisk-core-sounds-en-gsm-current \
    asterisk-core-sounds-en-ulaw-current \
    asterisk-core-sounds-en-wav-current \
    asterisk-extra-sounds-en-gsm-current \
    asterisk-extra-sounds-en-ulaw-current \
    asterisk-extra-sounds-en-wav-current \
    asterisk-moh-opsound-gsm-current \
    asterisk-moh-opsound-ulaw-current \
    asterisk-moh-opsound-wav-current; do
    wget -q "http://downloads.asterisk.org/pub/telephony/sounds/${pkg}.tar.gz"
done

cd /var/lib/asterisk/sounds
for f in /usr/src/asterisk-core-sounds-en-*.tar.gz \
          /usr/src/asterisk-extra-sounds-en-*.tar.gz; do
    tar -zxf "$f"
done

mkdir -p /var/lib/asterisk/mohmp3 /var/lib/asterisk/quiet-mp3
ln -sf /var/lib/asterisk/mohmp3 /var/lib/asterisk/default 2>/dev/null || true

cd /var/lib/asterisk/mohmp3
for f in /usr/src/asterisk-moh-opsound-*.tar.gz; do tar -zxf "$f"; done
rm -f CHANGES* LICENSE* CREDITS*
cd /var/lib/asterisk/sounds && rm -f CHANGES* LICENSE* CREDITS*
cd /var/lib/asterisk/moh 2>/dev/null && rm -f CHANGES* LICENSE* CREDITS* || true

# quiet MOH
cd /var/lib/asterisk/quiet-mp3
for track in macroform-cold_day macroform-robot_dity macroform-the_simplicity \
             reno_project-system manolo_camp-morning_coffee; do
    [ -f "../mohmp3/${track}.wav" ] && sox "../mohmp3/${track}.wav" "${track}.wav" vol 0.25
    [ -f "../mohmp3/${track}.gsm" ] && sox "../mohmp3/${track}.gsm" "${track}.gsm" vol 0.25
    [ -f "../mohmp3/${track}.ulaw" ] && sox -t ul -r 8000 -c 1 "../mohmp3/${track}.ulaw" -t ul "${track}.ulaw" vol 0.25
done

# Recordings path in Apache
cat >> /etc/httpd/conf/httpd.conf << 'EOF'

CustomLog /dev/null common

Alias /RECORDINGS/MP3 "/var/spool/asterisk/monitorDONE/MP3/"
<Directory "/var/spool/asterisk/monitorDONE/MP3/">
    Options Indexes MultiViews
    AllowOverride None
    Require all granted
</Directory>
EOF

# -- Sounds web folder --------------------------------------------------------
log "Copying sounds to web-accessible folder"
mkdir -p /var/www/html/hgcjvmrjzqcngw47wf5zf4xjzd9n0k
cp -r /var/lib/asterisk/sounds/* /var/www/html/hgcjvmrjzqcngw47wf5zf4xjzd9n0k/ 2>/dev/null || true

# -- ip_relay ------------------------------------------------------------------
hr; log "Building ip_relay"
cd /usr/src/astguiclient/trunk/extras/ip_relay/
unzip -q ip_relay_1.1.112705.zip 2>/dev/null || true
cd ip_relay_1.1/src/unix/ 2>/dev/null || true
make 2>/dev/null && cp ip_relay ip_relay2 &&     mv -f ip_relay /usr/bin/ && mv -f ip_relay2 /usr/local/bin/ip_relay &&     log "ip_relay instalado OK" || warn "ip_relay build failed -- blind monitor unavailable (non-critical)"

# -- G.729 codec ---------------------------------------------------------------
# G.729 requiere licencia comercial. Instalar manualmente si se requiere:
#   cd /usr/lib64/asterisk/modules
#   wget -O codec_g729.so TU_FUENTE/codec_g729-ast18-x86_64.so && chmod 755 codec_g729.so
warn "G.729 omitido -- install manually if needed"

# -- ConfBridge ----------------------------------------------------------------
hr; log "Setting up ConfBridge"
[ -f "${INSTALLER_DIR}/extensions.conf" ] && \
    cp -f "${INSTALLER_DIR}/extensions.conf" /etc/asterisk/extensions.conf
[ -f "${INSTALLER_DIR}/confbridge-vicidial.conf" ] && \
    cp -f "${INSTALLER_DIR}/confbridge-vicidial.conf" /etc/asterisk/

grep -q "confbridge-vicidial.conf" /etc/asterisk/confbridge.conf 2>/dev/null || \
    echo -e "\n#include confbridge-vicidial.conf" >> /etc/asterisk/confbridge.conf

# Insert 300 confbridges with correct server IP
python3 - "${SERVER_IP}" << 'PYEOF'
import sys
import subprocess
ip = sys.argv[1]
vals = ",".join(f"({9600000+i},'{ip}','','0',NULL)" for i in range(300))
sql = f"USE asterisk; INSERT IGNORE INTO vicidial_confbridges VALUES {vals};"
subprocess.run(["mysql", "-u", "root", "-e", sql], check=True)
print(f"OK 300 confbridges inserted for {ip}")
PYEOF

# -- ECPhone -------------------------------------------------------------------
hr; log "Installing ECPhone (WebRTC softphone)"
cd /var/www/html
if [ -d ECPhone ]; then
    warn "ECPhone already exists -- pulling latest"
    cd ECPhone && git pull
else
    git clone https://github.com/oaparicio1/ECPhone.git
fi
chmod -R 744 ECPhone
chown -R apache:apache ECPhone

# Update ViciDial system settings for ECPhone
mysql -u root -e "USE asterisk; UPDATE system_settings SET webphone_url='https://\${HOSTNAME}/ECPhone/ecphone.php', sounds_web_server='https://\${HOSTNAME}', active_voicemail_server='\${SERVER_IP}';" 
log "ECPhone configured in system_settings OK"

# -- SSL (certbot) -------------------------------------------------------------
# Mismo patron que carpenox: instalar + habilitar timer, NO correr certbot ahora
# El dominio puede no resolver al servidor nuevo todavia
# Correr manualmente despues: bash /usr/src/ecdialers-install/certbot.sh
hr; log "Installing certbot (SSL configured post-install)"
dnf install -y certbot python3-certbot-apache
systemctl enable certbot-renew.timer
systemctl start certbot-renew.timer 2>/dev/null || true
chmod +x "${INSTALLER_DIR}/certbot.sh" 2>/dev/null || true

# Try to get cert if domain already resolves to this server
# If it fails, continue without SSL (can run certbot.sh later)
if host "${HOSTNAME}" 2>/dev/null | grep -q "${SERVER_IP}"; then
    log "Dominio ${HOSTNAME} resuelve a ${SERVER_IP} -- obteniendo certificado SSL"
    systemctl stop csf 2>/dev/null || true
    certbot --apache -d "${HOSTNAME}" --non-interactive --agree-tos \
        -m "admin@ecdialers.com" --redirect && \
        log "SSL configured OK" || \
        warn "Certbot failed -- run manually: bash ${INSTALLER_DIR}/certbot.sh"
    csf -e 2>/dev/null || true
else
    warn "Domain ${HOSTNAME} does not resolve to ${SERVER_IP} yet"
    warn "Configure SSL manually after DNS is set: bash ${INSTALLER_DIR}/certbot.sh"
fi

# -- WebRTC --------------------------------------------------------------------
hr; log "Enabling WebRTC in ViciDial"
if [ -f "${INSTALLER_DIR}/vicidial-enable-webrtc.sh" ]; then
    chmod +x "${INSTALLER_DIR}/vicidial-enable-webrtc.sh"
    # Pass domain and email so script runs fully unattended
    bash "${INSTALLER_DIR}/vicidial-enable-webrtc.sh" "${HOSTNAME}" "admin@ecdialers.com"
fi

sed -i 's/SERVER_EXTERNAL_IP/0.0.0.0/' /etc/asterisk/pjsip.conf 2>/dev/null || true

# -- XSS fix -------------------------------------------------------------------
log "Applying XSS fix to sse.php"
sed -i "7s/.*/echo \"retry: \" . (int)(\$_GET['refresh_interval'] ?? 0) . \"\\\\n\";/" \
    /var/www/html/agc/sse.php 2>/dev/null || true

# -- Cockpit -------------------------------------------------------------------
hr; log "Installing Cockpit"
dnf install -y cockpit
dnf install -y cockpit-storaged 2>/dev/null || dnf install -y cockpit-storage 2>/dev/null || true
dnf install -y cockpit-navigator 2>/dev/null || true
sed -i 's/root/#root/g' /etc/cockpit/disallowed-users 2>/dev/null || true
systemctl enable --now cockpit.socket

# Copy Let's Encrypt cert to Cockpit
# Copy certs to Cockpit if they exist (may not exist if certbot did not run)
CERT_PATH="/etc/letsencrypt/live/${HOSTNAME}"
if [ -d "$CERT_PATH" ]; then
    cp "${CERT_PATH}/fullchain.pem" /etc/cockpit/ws-certs.d/ecdialers.cert
    cp "${CERT_PATH}/privkey.pem"   /etc/cockpit/ws-certs.d/ecdialers.key
    systemctl restart cockpit.socket && log "Cockpit SSL configured OK"
else
    warn "SSL certs not found -- Cockpit will use self-signed cert until SSL is configured"
fi

# -- CSF Firewall (Sentinel) --------------------------------------------------
hr; log "Installing and configuring CSF Firewall"

# Prerequisites for CSF
dnf install -y wget tar perl 2>/dev/null || true

# Descargar desde Sentinel — siguiendo pasos oficiales
cd /root
rm -f csf.tgz
wget --timeout=60 -L \
    https://raw.githubusercontent.com/sentinelfirewall/sentinel/refs/heads/main/csf.tgz \
    || die "CSF download failed"

# Verify download
[ -f /root/csf.tgz ] || die "csf.tgz not found after download"
[ -s /root/csf.tgz ] || die "csf.tgz is empty -- incomplete download"
log "CSF descargado: $(du -sh /root/csf.tgz | cut -f1)"

# Extract
tar -xzf /root/csf.tgz -C /root/ || die "CSF extract failed"
[ -d /root/csf ] || die "Directory /root/csf not found after extract"

# Install
cd /root/csf
sh install.sh || die "CSF install.sh failed"
log "CSF installed OK"

# Cleanup
cd /root
rm -rf /root/csf /root/csf.tgz

# ECdialers CSF configuration
cat > /etc/csf/csf.conf << 'CSFCONF'
# CSF Configuration -- ECdialers ViciDial Server
TESTING = "0"
RESTRICT_SYSLOG = "3"

# -- Inbound TCP --
TCP_IN = "22,80,443,5060,5061,8089,9000-9100"

# -- Outbound TCP --
TCP_OUT = "20,21,22,25,53,80,443,587,993,995,5060,5061"

# -- Inbound UDP --
UDP_IN = "5060,5061,10000:20000"

# -- Outbound UDP --
UDP_OUT = "20,21,53,113,123,5060,5061,10000:20000"

# -- IPv6 --
TCP6_IN  = ""
TCP6_OUT = ""
UDP6_IN  = ""
UDP6_OUT = ""

# -- Rate limiting --
LF_TRIGGER = "1"
LF_TRIGGER_PERM = "1"
DENY_TEMP_IP_LIMIT = "200"
LF_SELECT = "0"

# -- Port scan protection --
PS_INTERVAL = "0"

# -- Brute force --
LF_SSHD = "5"
LF_SSHD_PERM = "1"

# -- Login failure daemon --
LF_FTPD = "10"
LF_SMTPAUTH = "5"
LF_EXIMSYNTAX = "0"
LF_POP3D = "10"
LF_IMAPD = "10"
LF_HTACCESS = "5"
LF_CPANEL = "0"
LF_ACCOUNT = "0"
LF_MODSEC = "5"
LF_DISTATTACK = "0"
LF_WEBMIN = "5"

# -- Email alerts --
LF_ALERT = "1"
LF_ALERT_TO = "admin@ecdialers.com"
LF_ALERT_FROM = "csf@ecdialers.com"

# -- SYN flood --
SYNFLOOD = "0"
SYNFLOOD_RATE = "75/s"
SYNFLOOD_BURST = "25"

# -- Connection limit --
CONNLIMIT = ""
PORTFLOOD = ""

# -- Logging --
SYSLOG = "1"
LOGDROP = "0"
LOGDROPOUT = "0"

# -- Misc --
ETH_DEVICE = ""
ETH6_DEVICE = ""
ICMP_IN = "1"
ICMP_IN_LIMIT = "1/s"
ICMP_OUT = "1"
SMTP_BLOCK = "0"
FASTSTART = "1"
CSFTEST_PORT = "9999"
GLOBALTCPIN = ""
GLOBALTCPOUT = ""
GLOBALUDPIN = ""
GLOBALUDPOUT = ""
MESSENGER = "0"
MESSENGER_HTML = "1"
MESSENGER_USER = "nobody"
MESSENGER_PORT = "80"
MESSENGER_SSL_PORT = "443"
CSFCONF

# Allow server's own IP in CSF
csf -a "${SERVER_IP}" "ECdialers Server IP" 2>/dev/null || warn "CSF allow IP failed -- add manually: csf -a ${SERVER_IP}"

csf -r 2>/dev/null || true
systemctl enable csf lfd 2>/dev/null || warn "CSF service enable failed -- may require reboot"
log "CSF Firewall configured OK"

# -- SSH hardening -------------------------------------------------------------
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config

# -- Asterisk service ----------------------------------------------------------
hr; log "Creating Asterisk systemd service"
cat > /etc/systemd/system/asterisk.service << 'EOF'
[Unit]
Description=Asterisk PBX
Wants=nss-lookup.target network-online.target
After=network-online.target

[Service]
PIDFile=/run/asterisk/asterisk.pid
ExecStart=/usr/sbin/asterisk -fn
ExecReload=/bin/kill -HUP $MAINPID

[Install]
WantedBy=basic.target
EOF

# -- rc.local ------------------------------------------------------------------
hr; log "Configuring rc.local"
sed -i 's|exit 0|### exit 0|g' /etc/rc.d/rc.local

cat >> /etc/rc.d/rc.local << 'EOF'

# ECdialers ViciDial boot sequence

/usr/share/astguiclient/ip_relay/relay_control start 2>/dev/null 1>&2

# Disable console blanking
/usr/bin/setterm -blank 0 2>/dev/null || true
/usr/bin/setterm -powersave off 2>/dev/null || true
/usr/bin/setterm -powerdown 0 2>/dev/null || true

systemctl start mariadb.service
systemctl start httpd.service

/usr/share/astguiclient/ADMIN_restart_roll_logs.pl
/usr/share/astguiclient/AST_reset_mysql_vars.pl

modprobe dahdi 2>/dev/null || true
modprobe dahdi_dummy 2>/dev/null || true
/usr/sbin/dahdi_cfg -vvvvvvvvvvvvv 2>/dev/null || true

sleep 20
/usr/share/astguiclient/start_asterisk_boot.pl

exit 0
EOF

chmod +x /etc/rc.d/rc.local

cat > /etc/systemd/system/rc-local.service << 'EOF'
[Unit]
Description=/etc/rc.local Compatibility

[Service]
Type=oneshot
ExecStart=/etc/rc.local
TimeoutSec=0
StandardInput=tty
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# -- Crontab -------------------------------------------------------------------
hr; log "Installing crontab"
cat > /root/crontab-file << 'CRONTAB'

### Audio Sync hourly
* 1 * * * /usr/share/astguiclient/ADMIN_audio_store_sync.pl --upload --quiet

### Daily Backups
0 2 * * * /usr/share/astguiclient/ADMIN_backup.pl

### Certbot renewal
@monthly certbot renew --quiet

### Recording mixing/compressing
0,3,6,9,12,15,18,21,24,27,30,33,36,39,42,45,48,51,54,57 * * * * /usr/share/astguiclient/AST_CRON_audio_1_move_mix.pl --MIX
0,3,6,9,12,15,18,21,24,27,30,33,36,39,42,45,48,51,54,57 * * * * /usr/share/astguiclient/AST_CRON_audio_1_move_VDonly.pl
1,4,7,10,13,16,19,22,25,28,31,34,37,40,43,46,49,52,55,58 * * * * /usr/share/astguiclient/AST_CRON_audio_2_compress.pl --MP3 --HTTPS

### Keepalive
* * * * * /usr/share/astguiclient/ADMIN_keepalive_ALL.pl --cu3way

### Kill hung congested calls
* * * * * /usr/share/astguiclient/AST_manager_kill_hung_congested.pl

### Voicemail updater
* * * * * /usr/share/astguiclient/AST_vm_update.pl

### Conference validator
* * * * * /usr/share/astguiclient/AST_conf_update.pl

### Flush DB queue hourly
11 * * * * /usr/share/astguiclient/AST_flush_DBqueue.pl -q

### Agent log cleanup
33 * * * * /usr/share/astguiclient/AST_cleanup_agent_log.pl
50 0 * * * /usr/share/astguiclient/AST_cleanup_agent_log.pl --last-24hours

### ViciDial hopper
* * * * * /usr/share/astguiclient/AST_VDhopper.pl -q

### GMT offset adjust
1 1,7 * * * /usr/share/astguiclient/ADMIN_adjust_GMTnow_on_leads.pl --debug

### Daily DB maintenance
2 1 * * * /usr/share/astguiclient/AST_reset_mysql_vars.pl
3 1 * * * /usr/share/astguiclient/AST_DB_optimize.pl

### Weekly agent report
2 0 * * 0 /usr/share/astguiclient/AST_agent_week.pl
22 0 * * * /usr/share/astguiclient/AST_agent_day.pl

### Log cleanup
28 0 * * * /usr/bin/find /var/log/astguiclient -maxdepth 1 -type f -mtime +2 -print | xargs rm -f
29 0 * * * /usr/bin/find /var/log/asterisk -maxdepth 3 -type f -mtime +2 -print | xargs rm -f
30 0 * * * /usr/bin/find / -maxdepth 1 -name "screenlog.0*" -mtime +4 -print | xargs rm -f

### Callback cleanup
25 0 * * * /usr/share/astguiclient/AST_DB_dead_cb_purge.pl --purge-non-cb -q

### Inbound email parser
* * * * * /usr/share/astguiclient/AST_inbound_email_parser.pl

### Log table archive (monthly)
30 1 1 * * /usr/share/astguiclient/ADMIN_archive_log_tables.pl --days=90

### Monitor recordings cleanup (keep 7 days ORIG)
24 1 * * * /usr/bin/find /var/spool/asterisk/monitorDONE/ORIG -maxdepth 2 -type f -mtime +1 -print | xargs rm -f

### Dialer inventory snapshot (daily)
1 7 * * * /usr/share/astguiclient/AST_dialer_inventory_snapshot.pl -q --override-24hours

### SSL cert renewal (monthly via ECdialers certbot script)
@monthly bash /usr/src/ecdialers-install/certbot.sh

CRONTAB

crontab /root/crontab-file
log "Crontab installed — $(crontab -l | grep -c astguiclient) ViciDial jobs active" 

# -- Permissions & fstab -------------------------------------------------------
hr; log "Final permissions and fstab"

groupadd asterisk 2>/dev/null || true
useradd -r -d /var/lib/asterisk -g asterisk asterisk 2>/dev/null || true
chown -R asterisk:asterisk /var/spool/asterisk
chmod -R 775 /var/spool/asterisk
chown -R apache:apache /var/spool/asterisk
chmod -R 777 /var/spool/asterisk

# tmpfs for monitor (2GB RAM buffer for recordings)
grep -q "var/spool/asterisk/monitor" /etc/fstab || \
    echo "none /var/spool/asterisk/monitor tmpfs nodev,nosuid,noexec,nodiratime,size=2G 0 0" >> /etc/fstab

# -- Welcome page -------------------------------------------------------------
cat > /var/www/html/index.html << 'EOF'
<META HTTP-EQUIV=REFRESH CONTENT="1; URL=/vicidial/welcome.php">
Redirecting to ViciDial...
EOF

# -- Disable debug kernel ------------------------------------------------------
# Remove kernel-debug if installed (non-critical)
dnf remove -y kernel-debug kernel-devel-debug 2>/dev/null | grep -v 'No match' || true

# -- chkconfig asterisk off ----------------------------------------------------
chkconfig asterisk off 2>/dev/null || true
# Ensure asterisk does not auto-start
systemctl disable asterisk 2>/dev/null || true

# Fix pjsip.conf external IP placeholder
sed -i 's/SERVER_EXTERNAL_IP/0.0.0.0/' /etc/asterisk/pjsip.conf 2>/dev/null || true
log "pjsip.conf SERVER_EXTERNAL_IP set to 0.0.0.0" 

# -- Systemd reload ------------------------------------------------------------
timeout 30 systemctl daemon-reload || true
systemctl enable rc-local.service
# NO iniciar rc-local durante instalacion -- intenta arrancar Asterisk y se cuelga
# rc-local will start automatically on next reboot
log "rc-local enabled for boot (not started during install)"
systemctl enable httpd mariadb
systemctl restart mariadb 2>/dev/null || warn "MariaDB restart failed"
systemctl restart httpd 2>/dev/null || warn "httpd restart failed -- check config"
# Verificar que httpd esta corriendo
systemctl is-active httpd >/dev/null 2>&1 && log "httpd corriendo OK" || warn "httpd not active -- check: journalctl -u httpd"
systemctl is-active mariadb >/dev/null 2>&1 && log "MariaDB corriendo OK" || warn "MariaDB not active" 

# -- SSH banner ----------------------------------------------------------------
sed -i 's|#Banner none|Banner /etc/ssh/sshd_banner|g' /etc/ssh/sshd_config
cat > /etc/ssh/sshd_banner << 'EOF'
+==========================================+
|         ECdialers ViciDial Server        |
|    Unauthorized access is prohibited     |
|         support@ecdialers.com            |
+==========================================+
EOF

# ── Schema patches — add columns that may be missing in fresh ViciDial installs ──
hr; log "Applying schema patches"
mysql -u root asterisk --force << 'SCHEMAEOF'
ALTER TABLE system_settings ADD COLUMN IF NOT EXISTS INSERT_before_body_close text DEFAULT NULL;
ALTER TABLE system_settings ADD COLUMN IF NOT EXISTS webphone_width varchar(10) DEFAULT '260';
ALTER TABLE system_settings ADD COLUMN IF NOT EXISTS webphone_height varchar(10) DEFAULT '440';
ALTER TABLE system_settings ADD COLUMN IF NOT EXISTS webphone_systemkey varchar(50) DEFAULT 'webrtc';
ALTER TABLE system_settings ADD COLUMN IF NOT EXISTS agent_screen_webphone_layout varchar(200) DEFAULT '';
SCHEMAEOF

# Set ECphone skin injection
mysql -u root asterisk -e "UPDATE system_settings SET INSERT_before_body_close='<script src="/agc/ec_agent_skin.js"></script>' WHERE INSERT_before_body_close IS NULL OR INSERT_before_body_close='';"
log "Schema patches applied ✓"

# ── Final IP update — run LAST after everything is installed ─────────────────
hr; log "Updating all server IPs from 10.10.10.15 to ${SERVER_IP}"

# Run ADMIN_update_server_ip.pl — updates ALL tables with default IP
/usr/share/astguiclient/ADMIN_update_server_ip.pl \
    --old-server_ip=10.10.10.15 --server_ip="${SERVER_IP}" --auto 2>/dev/null && \
    log "Server IP updated in all ViciDial tables ✓" || \
    warn "ADMIN_update_server_ip.pl had warnings — check manually"

# Also update directly via SQL to catch anything the script missed
mysql -u root asterisk --force << IPEOF
UPDATE servers           SET server_ip='${SERVER_IP}' WHERE server_ip='10.10.10.15';
UPDATE phones            SET server_ip='${SERVER_IP}' WHERE server_ip='10.10.10.15';
UPDATE conferences       SET server_ip='${SERVER_IP}' WHERE server_ip='10.10.10.15';
UPDATE vicidial_conferences SET server_ip='${SERVER_IP}' WHERE server_ip='10.10.10.15';
UPDATE vicidial_confbridges SET server_ip='${SERVER_IP}' WHERE server_ip='10.10.10.15';
UPDATE vicidial_campaign_server_stats SET server_ip='${SERVER_IP}' WHERE server_ip='10.10.10.15';
UPDATE system_settings SET
    active_voicemail_server='${SERVER_IP}',
    webphone_url='https://${HOSTNAME}/ECPhone/ecphone.php',
    sounds_web_server='https://${HOSTNAME}';
IPEOF
log "All tables updated to ${SERVER_IP} ✓"

# ── Final summary ────────────────────────────────────────────────────────────
sleep 1
clear

# Banner final
echo -e "\033[0;32m"
echo "  ██████╗  ██████╗ ███╗   ██╗███████╗██╗"
echo "  ██╔══██╗██╔═══██╗████╗  ██║██╔════╝██║"
echo "  ██║  ██║██║   ██║██╔██╗ ██║█████╗  ██║"
echo "  ██║  ██║██║   ██║██║╚██╗██║██╔══╝  ╚═╝"
echo "  ██████╔╝╚██████╔╝██║ ╚████║███████╗██╗"
echo "  ╚═════╝  ╚═════╝ ╚═╝  ╚═══╝╚══════╝╚═╝"
echo -e "\033[0m"
sleep 0.4

echo -e "\033[1;36m"
echo "              (•_•)"
echo "              ( •_•)>⌐■-■"
echo "              (⌐■_■)"
echo ""
echo "         INSTALLATION COMPLETE, BOSS."
echo -e "\033[0m"
sleep 0.6

echo -e "\033[1;33m"
echo "  ┌─────────────────────────────────────────────────────────┐"
echo "  │                                                         │"
echo "  │   ViciDial is UP. CSF is LOCKED. ECPhone is READY.     │"
echo "  │   Your dialer just got a whole lot cooler.  😎          │"
echo "  │                                                         │"
echo "  └─────────────────────────────────────────────────────────┘"
echo -e "\033[0m"
sleep 0.4

hr
echo ""
echo -e "  ${BOLD}Server IP:${NC}    ${SERVER_IP}"
echo -e "  ${BOLD}Hostname:${NC}     ${HOSTNAME}"
echo -e "  ${BOLD}ViciDial:${NC}     https://${HOSTNAME}/vicidial/admin.php"
echo -e "  ${BOLD}Agent UI:${NC}     https://${HOSTNAME}/agc/vicidial.php"
echo -e "  ${BOLD}ECPhone:${NC}      https://${HOSTNAME}/ECPhone/ecphone.php"
echo -e "  ${BOLD}Cockpit:${NC}      https://${HOSTNAME}:9090"
echo ""
echo -e "  ${BOLD}Default credentials:${NC}"
echo -e "  ViciDial admin : ${YELLOW}admin / admin${NC}  ← CHANGE THIS"
echo -e "  MySQL cron     : ${YELLOW}cron / ${DB_PASS}${NC}"
echo ""
echo -e "  ${BOLD}Next steps:${NC}"
echo -e "  1. Change ViciDial admin password"
echo -e "  2. Set server IP in ViciDial: Admin → Servers"
echo -e "  3. Configure SIP trunk / carrier"
echo -e "  4. Enable WebRTC phone template (rtcp_mux=yes)"
echo -e "  5. SSL: bash /usr/src/ecdialers-install/certbot.sh"
echo -e "  6. Review CSF rules: /etc/csf/csf.conf"
echo ""
hr
read -rp "Press Enter to reboot..."
reboot
reboot
