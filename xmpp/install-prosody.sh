#!/bin/bash

set -e

source "$(dirname "${BASH_SOURCE[0]}")/libs.sh"

SCRIPT_VERSION="1.0.0"
BACKUP_DIR="/etc/prosody/backups/$(date +%Y%m%d_%H%M%S)"
LOG_FILE="/var/log/prosody-install.log"

FN_LOG_FILE() {
  local level="$1"; shift
  FN_LOG "$level" "$*"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" >> "$LOG_FILE"
}

if [ "$EUID" -ne 0 ]; then
  FN_LOG error "Please run as root"
  exit 1
fi

FN_LOG_FILE info "Starting Prosody installation"

FN_PROMPT DOMAIN "XMPP domain" "" "domain" "true"

FN_PROMPT ADMIN_USER "Admin username" "" "username" "true"

while true; do
  FN_CMSG "6:0:B" "Admin password (min 12 chars): "
  read -s ADMIN_PASS
  echo
  if [ ${#ADMIN_PASS} -ge 12 ]; then
    break
  fi
  FN_LOG warn "Password too short"
done

FN_PROMPT ADMIN_IP "Admin IP address" "" "ip" "true"

ENABLE_MUC=false
if FN_YN "Enable group chat?"; then
  ENABLE_MUC=true
fi

ENABLE_UPLOAD=false
if FN_YN "Enable file uploads?"; then
  ENABLE_UPLOAD=true
fi

FN_LOG_FILE info "Installing packages"
apt-get update
apt-get install -y prosody certbot ufw fail2ban lua5.2 lua-sec

if [ -f /etc/prosody/prosody.cfg.lua ]; then
  mkdir -p "$BACKUP_DIR"
  cp /etc/prosody/prosody.cfg.lua "$BACKUP_DIR/"
fi

FN_LOG_FILE info "Configuring Prosody"

cat > /etc/prosody/prosody.cfg.lua << EOF
admins = { "$ADMIN_USER@$DOMAIN" }

modules_enabled = {
  "roster";
  "saslauth";
  "tls";
  "dialback";
  "disco";
  "private";
  "vcard4";
  "version";
  "uptime";
  "time";
  "ping";
  "register";
  "admin_adhoc";
  "bosh";
  "websocket";
  "carbons";
  "smacks";
  "blocklist";
EOF

if [ "$ENABLE_MUC" = true ]; then
  echo '  "muc";' >> /etc/prosody/prosody.cfg.lua
fi

if [ "$ENABLE_UPLOAD" = true ]; then
  echo '  "http_upload";' >> /etc/prosody/prosody.cfg.lua
fi

cat >> /etc/prosody/prosody.cfg.lua << EOF
}

allow_registration = false
authentication = "internal_hashed"

log = {
  info = "/var/log/prosody/prosody.log";
  error = "/var/log/prosody/prosody.err";
}

certificates = "/etc/prosody/certs"
c2s_require_encryption = true
s2s_require_encryption = true

VirtualHost "$DOMAIN"
  ssl = {
    certificate = "/etc/prosody/certs/$DOMAIN/fullchain.pem";
    key = "/etc/prosody/certs/$DOMAIN/privkey.pem";
  }
EOF

if [ "$ENABLE_MUC" = true ]; then
  cat >> /etc/prosody/prosody.cfg.lua << EOF

Component "conference.$DOMAIN" "muc"
  restrict_room_creation = "admin"
EOF
fi

if [ "$ENABLE_UPLOAD" = true ]; then
  cat >> /etc/prosody/prosody.cfg.lua << EOF

Component "upload.$DOMAIN" "http_upload"
  http_upload_file_size_limit = 10485760
EOF
fi

FN_LOG_FILE info "Getting SSL certificates"
systemctl stop prosody 2>/dev/null || true

certbot certonly --standalone --non-interactive --agree-tos \
  --register-unsafely-without-email -d "$DOMAIN"

if [ "$ENABLE_MUC" = true ]; then
  certbot certonly --standalone --non-interactive --agree-tos \
    --register-unsafely-without-email -d "conference.$DOMAIN"
fi

if [ "$ENABLE_UPLOAD" = true ]; then
  certbot certonly --standalone --non-interactive --agree-tos \
    --register-unsafely-without-email -d "upload.$DOMAIN"
fi

# 인증서 링크
mkdir -p "/etc/prosody/certs/$DOMAIN"
ln -sf "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "/etc/prosody/certs/$DOMAIN/"
ln -sf "/etc/letsencrypt/live/$DOMAIN/privkey.pem" "/etc/prosody/certs/$DOMAIN/"
chown -R prosody:prosody /etc/prosody/certs

FN_LOG_FILE info "Configuring firewall"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow 5222/tcp  # XMPP client
ufw allow 5269/tcp  # XMPP server
# ufw allow 80/tcp    # HTTP
# ufw allow 443/tcp   # HTTPS
ufw --force enable

FN_LOG_FILE info "Setting up fail2ban"
cat > /etc/fail2ban/filter.d/prosody-auth.conf << 'EOF'
[Definition]
failregex = Failed authentication.*from IP: <HOST>
ignoreregex =
EOF

cat >> /etc/fail2ban/jail.local << EOF

[prosody-auth]
enabled = true
filter = prosody-auth
logpath = /var/log/prosody/prosody.log
maxretry = 5
bantime = 3600
EOF

systemctl restart fail2ban

FN_LOG_FILE info "Starting Prosody"
systemctl enable prosody
systemctl start prosody
sleep 3

echo "$ADMIN_PASS" | prosodyctl adduser "$ADMIN_USER@$DOMAIN"

echo '#!/bin/bash
certbot renew --quiet --post-hook "systemctl reload prosody"' > /etc/cron.daily/prosody-cert-renewal
chmod +x /etc/cron.daily/prosody-cert-renewal

echo
FN_CMSG "2:0:B" "Install Complete"
echo "Domain: $DOMAIN"
echo "Admin Info: $ADMIN_USER@$DOMAIN"
echo "Prosody status: $(systemctl is-active prosody)"
echo "Configuration: /etc/prosody/prosody.cfg.lua"
echo "Logs: /var/log/prosody/"
echo "Backup: $BACKUP_DIR"
echo

if [ "$ENABLE_MUC" = true ]; then
  echo "Group chat: conference.$DOMAIN"
fi

if [ "$ENABLE_UPLOAD" = true ]; then
  echo "File upload: upload.$DOMAIN"
fi

FN_LOG_FILE info "Installation completed"