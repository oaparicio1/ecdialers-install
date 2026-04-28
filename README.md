# ECdialers ViciDial Install Scripts

Auto-installer for **ViciDial** on **AlmaLinux 9** — built and maintained by [ECdialers](https://ecdialers.com).

Includes:
- ViciDial (Asterisk 18.21.0-vici + astguiclient trunk)
- MariaDB 10.5 + full ViciDial schema
- DAHDI 3.4.0
- PHP 7.4 (Remi)
- **ECPhone** — ECdialers WebRTC softphone
- **CSF** — ConfigServer Firewall (replaces firewalld)
- Cockpit web admin
- SSL via certbot
- Full ViciDial crontab
- ConfBridge setup
- G.729 codec

---

## Pre-install (run after fresh AlmaLinux 9 install)

```bash
# Language and locale
dnf install -y glibc-langpack-en
localectl set-locale en_US.UTF-8
timedatectl set-timezone America/New_York

# Updates and git
yum check-update
yum update -y
yum -y install epel-release git
yum update -y
yum install kernel* --exclude=kernel-debug* -y

# Disable SELinux
sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config

# Clone installer
cd /usr/src/
git clone https://github.com/oaparicio1/ecdialers-install.git

reboot
```

---

## Install

```bash
cd /usr/src/ecdialers-install
chmod +x main-installer.sh
./main-installer.sh
```

The installer is interactive — it will ask for:
- Hostname (must resolve to the server's public IP for SSL)
- Timezone
- MySQL cron password

Total install time: **~20-30 minutes**.

---

## Post-install

After reboot:

1. Login to ViciDial Admin: `https://YOUR-DOMAIN/vicidial/admin.php`
   - Default: `admin` / `admin` ← **change immediately**
2. Go to **Admin → Servers** → verify server IP
3. Configure a SIP carrier under **Carriers**
4. Create a campaign and phone extension
5. For WebRTC, set `rtcp_mux=yes` in the phone template

Full post-install guide: [ECdialers Knowledge Base](https://ecdialers.com)

---

## Included Scripts

| Script | Purpose |
|---|---|
| `main-installer.sh` | Full AlmaLinux 9 install (Asterisk 18 + CSF) |
| `vicidial-enable-webrtc.sh` | Enable WebRTC on existing install |
| `add-dialer-to-DB.sh` | Add addon dialer to cluster DB |
| `certbot.sh` | SSL cert renewal helper |

---

## Firewall (CSF)

CSF is installed with ECdialers defaults. Key open ports:

| Port | Protocol | Purpose |
|---|---|---|
| 22 | TCP | SSH |
| 80, 443 | TCP | HTTP/HTTPS |
| 5060, 5061 | TCP/UDP | SIP |
| 8089 | TCP | WebSocket (WebRTC) |
| 10000-20000 | UDP | RTP audio |

To add an IP to the whitelist:
```bash
csf -a IP.AD.DR.ESS "Description"
```

---

## Support

- Email: support@ecdialers.com
- ECPhone repo: [oaparicio1/ECPhone](https://github.com/oaparicio1/ECPhone)
