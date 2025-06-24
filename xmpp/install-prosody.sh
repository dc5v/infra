#!/bin/bash

set -e

SCRIPT_VERSION="1.0.0"
BACKUP_DIR="/etc/prosody/backups/$(date +%Y%m%d_%H%M%S)"
LOG_FILE="/var/log/prosody-install.log"

FN_LOG() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

FN_DOMAIN_REGEX() {
  if [[ ! "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]\.[a-zA-Z]{2,}$ ]]; then
    return 1
  fi
  return 0
}

FN_IP_REGEX() {
  if [[ ! "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    return 1
  fi
  return 0
}

FN_YN() {
  while true; do
    read -p "$1 [y/n]: " answer
    case $answer in
      [Yy]* ) return 0;;
      [Nn]* ) return 1;;
      * ) echo "Please answer y or n.";;
    esac
  done
}

# sudo check
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

. /etc/os-release
if [ "$ID" != "ubuntu" ] || [ "$VERSION_ID" != "22.04" ]; then
  echo "This script requires Ubuntu 22.04"
  exit 1
fi

FN_LOG "Starting Prosody installation"

# domain
while true; do
  read -p "XMPP domain: " DOMAIN
  if FN_DOMAIN_REGEX "$DOMAIN"; then
    break
  fi
  echo "Invalid domain"
done

# admin username
read -p "Admin username: " ADMIN_USER

# admin password
while true; do
  read -s -p "Admin password (min 12 chars): " ADMIN_PASS
  echo
  if [ ${#ADMIN_PASS} -ge 12 ]; then
    break
  fi
  echo "Password too short"
done

# admin IP
while true; do
  read -p "Admin IP address: " ADMIN_IP
  if FN_IP_REGEX "$ADMIN_IP"; then
    break
  fi
  echo "Invalid IP"
done

# Optional features
ENABLE_MUC=false
if FN_YN "Enable group chat?"; then
  ENABLE_MUC=true
fi

ENABLE_UPLOAD=false
if FN_YN "Enable file uploads?"; then
  ENABLE_UPLOAD=true
fi

FN_LOG "Installing packages"
apt-get update
apt-get install -y prosody certbot ufw fail2ban lua5.2 lua-sec

# Backup existing config
if [ -f /etc/prosody/prosody.cfg.lua ]; then
  mkdir -p "$BACKUP_DIR"
  cp /etc/prosody/prosody.cfg.lua "$BACKUP_DIR/"
fi

FN_LOG "Configuring Prosody"

# Create basic config
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

FN_LOG "Getting SSL certificates"
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

# Link certificates
mkdir -p "/etc/prosody/certs/$DOMAIN"
ln -sf "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "/etc/prosody/certs/$DOMAIN/"
ln -sf "/etc/letsencrypt/live/$DOMAIN/privkey.pem" "/etc/prosody/certs/$DOMAIN/"
chown -R prosody:prosody /etc/prosody/certs

FN_LOG "Configuring firewall"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow 5222/tcp  # XMPP client
ufw allow 5269/tcp  # XMPP server
ufw allow 80/tcp  # HTTP
ufw allow 443/tcp   # HTTPS
ufw --force enable

FN_LOG "Setting up fail2ban"
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

FN_LOG "Starting Prosody"
systemctl enable prosody
systemctl start prosody
sleep 3

# Create admin user
echo "$ADMIN_PASS" | prosodyctl adduser "$ADMIN_USER@$DOMAIN"

# Setup cert renewal
echo '#!/bin/bash
certbot renew --quiet --post-hook "systemctl reload prosody"' > /etc/cron.daily/prosody-cert-renewal
chmod +x /etc/cron.daily/prosody-cert-renewal

echo ; echo "[O] Install Complete ==="
echo "Domain: $DOMAIN"
echo "Admin Info: $ADMIN_USER@$DOMAIN"
echo "Prosody status: $(systemctl is-active prosody)"
echo "Configuration: /etc/prosody/prosody.cfg.lua"
echo "Logs: /var/log/prosody/"
echo "Backup: $BACKUP_DIR"; echo 

if [ "$ENABLE_MUC" = true ]; then
  echo "Group chat: conference.$DOMAIN"
fi

if [ "$ENABLE_UPLOAD" = true ]; then
  echo "File upload: upload.$DOMAIN"
fi

FN_LOG "Installation completed"