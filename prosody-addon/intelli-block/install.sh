#!/bin/bash
set -euo pipefail

INSTALL_ROOT="$(cd "$(dirname "$0")" && pwd)"
DEST_PROSODY="/etc/prosody"
DEST_BIN="/usr/local/bin"
DEST_CRON="/etc/cron.daily"
DEST_LOG="/var/log"
DEST_CACHE="/var/cache"

echo "=== Install s2s_intelli_blacklist ==="; echo

read -rp "AbuseIPDB API key: " API_KEY
read -rp "AbuseIPDB threshold (default: 70): " ABUSE_THRESHOLD
read -rp "Blacklist expire limit (seconds, default: 86400): " EXPIRY
read -rp "Run now? (y/n): " RUN_NOW

[[ -z "$ABUSE_THRESHOLD" ]] && ABUSE_THRESHOLD=70
[[ -z "$EXPIRY" ]] && EXPIRY=86400

mkdir -p "$DEST_PROSODY" "$DEST_BIN" "$DEST_CRON" "$DEST_LOG" "$DEST_CACHE"

echo "Install shell scripts"
install -m 755 "$INSTALL_ROOT/s2s_intelli_blacklist.sh" "$DEST_BIN/s2s_intelli_blacklist.sh"

echo "Install lua scripts"
install -m 644 "$INSTALL_ROOT/s2s_intelli_blacklist_blocked.lua" "$DEST_PROSODY/s2s_intelli_blacklist_blocked.lua"
install -m 644 "$INSTALL_ROOT/s2s_intelli_blacklist_active.lua" "$DEST_PROSODY/s2s_intelli_blacklist_active.lua"

echo "Install configs"
cat > "$DEST_PROSODY/s2s_intelli_blacklist.conf" <<EOF
score.authfail=2
score.tlsfail=2
score.dnsfail=3
score.suffixmatch=3

abuseipdb.threshold=${ABUSE_THRESHOLD}
abuseipdb.maxscore=10
blacklist.score_required=10
blacklist.expiry_seconds=${EXPIRY}
EOF

echo "API key to .env"
cat > "$DEST_PROSODY/.env" <<EOF
ABUSEIPDB_API_KEY=${API_KEY}
EOF
chmod 600 "$DEST_PROSODY/.env"

echo "Install cron jobs"
install -m 755 "$INSTALL_ROOT/cron.d/s2s_intelli_blacklist" "$DEST_CRON/s2s_intelli_blacklist"

touch "$DEST_CACHE/s2s_intelli_blacklist_cache.json"
chmod 600 "$DEST_CACHE/s2s_intelli_blacklist_cache.json"

touch "$DEST_LOG/s2s_intelli_blacklist.log"
chmod 640 "$DEST_LOG/s2s_intelli_blacklist.log"

if [[ "$RUN_NOW" =~ ^[Yy]$ ]]; then
  echo "[*] Running initial update..."
  "$DEST_BIN/s2s_intelli_blacklist.sh"
fi

echo; echo "======================"
echo "[O] Install complete"
echo "Config: $DEST_PROSODY/s2s_intelli_blacklist.conf"
echo "API key: $DEST_PROSODY/.env"
echo "Lua output: $DEST_PROSODY/s2s_intelli_blacklist_active.lua"; echo
