#!/bin/bash
set -euo pipefail

# Path
readonly BASE_DIR="/etc/prosody"
readonly CACHE_FILE="/var/cache/s2s_intelli_blacklist_cache.json"
readonly LOG_FILE="/var/log/s2s_intelli_blacklist.log"
readonly CONFIG_FILE="${BASE_DIR}/s2s_intelli_blacklist.conf"
readonly ENV_FILE="${BASE_DIR}/.env"
readonly OUTPUT_LUA="${BASE_DIR}/s2s_intelli_blacklist_blocked.lua"

# Log
FN_LOG() {
    local LEVEL="$1"
    shift
    local TS
    TS="$(date '+%Y-%m-%d %H:%M:%S')"
    case "$LEVEL" in
        INFO) echo "[$TS] [INFO] $*" | tee -a "$LOG_FILE" ;;
        WARN) echo "[$TS] [WARN] $*" | tee -a "$LOG_FILE" >&2 ;;
        ERROR) echo "[$TS] [ERROR] $*" | tee -a "$LOG_FILE" >&2 ;;
        FATAL) echo "[$TS] [FATAL] $*" | tee -a "$LOG_FILE" >&2; exit 1 ;;
        *) echo "[$TS] [UNKNOWN] $*" | tee -a "$LOG_FILE" >&2 ;;
    esac
}

# Env
if [[ ! -f "$ENV_FILE" ]]; then
    FN_LOG FATAL "Missing environment file: $ENV_FILE"
fi
source "$ENV_FILE"
if [[ -z "${ABUSEIPDB_API_KEY:-}" ]]; then
    FN_LOG FATAL "ABUSEIPDB_API_KEY not set in $ENV_FILE"
fi

# Config
declare -A CONFIG
while IFS='=' read -r k v; do
    k="${k// /}"; v="${v// /}"
    [[ -z "$k" || "$k" == \#* ]] && continue
    CONFIG["$k"]="$v"
done < "$CONFIG_FILE"

SCORE_AUTH="${CONFIG[score.authfail]:-2}"
SCORE_TLS="${CONFIG[score.tlsfail]:-2}"
SCORE_DNS="${CONFIG[score.dnsfail]:-3}"
SCORE_SUFFIX="${CONFIG[score.suffixmatch]:-3}"
SCORE_REQUIRED="${CONFIG[blacklist.score_required]:-10}"
EXPIRY="${CONFIG[blacklist.expiry_seconds]:-86400}"
ABUSE_THRESHOLD="${CONFIG[abuseipdb.threshold]:-70}"
ABUSE_MAXSCORE="${CONFIG[abuseipdb.maxscore]:-10}"

NOW=$(date +%s)
declare -A BLACKLIST

# Abuse
lookup_abuse_score() {
    local ip="$1"
    [[ -z "$ip" ]] && return

    # Cache
    if [[ -f "$CACHE_FILE" ]]; then
        local cached
        cached=$(jq -r --arg ip "$ip" '.[$ip]' "$CACHE_FILE" 2>/dev/null || echo null)
        [[ "$cached" != "null" ]] && echo "$cached" && return
    fi

    # API
    local json
    json=$(curl -sS --fail -G \
        --data-urlencode "ipAddress=$ip" \
        --data-urlencode "maxAgeInDays=30" \
        -H "Key: $ABUSEIPDB_API_KEY" \
        -H "Accept: application/json" \
        "https://api.abuseipdb.com/api/v2/check" || true)

    local score=0
    if [[ -n "$json" ]]; then
        score=$(echo "$json" | jq -r '.data.abuseConfidenceScore // 0' || echo 0)
    else
        FN_LOG WARN "AbuseIPDB lookup failed for $ip"
    fi

    # Save
    tmpfile=$(mktemp)
    if [[ -f "$CACHE_FILE" ]]; then
        jq --arg ip "$ip" --argjson score "$score" '. + {($ip): $score}' "$CACHE_FILE" > "$tmpfile" && mv "$tmpfile" "$CACHE_FILE"
    else
        echo "{\"$ip\": $score}" > "$CACHE_FILE"
    fi

    echo "$score"
}

# Score
calculate_score() {
    local domain="$1"
    local score=0

    # DNS
    if ! dig +short "_xmpp-server._tcp.${domain}" SRV | grep -q .; then
        score=$((score + SCORE_DNS))
    fi

    # IP
    local ip
    ip=$(dig +short "$domain" A | head -n1)
    if [[ -n "$ip" ]]; then
        local abuse
        abuse=$(lookup_abuse_score "$ip")
        if [[ "$abuse" -ge "$ABUSE_THRESHOLD" ]]; then
            local weight=$(( (abuse * ABUSE_MAXSCORE) / 100 ))
            score=$((score + weight))
        fi
    fi

    # TLD
    if [[ "$domain" =~ \.(tk|ml|ga|cf|gq)$ ]]; then
        score=$((score + SCORE_SUFFIX))
    fi

    echo "$score"
}

# Domains
DOMAINS=()
while read -r d; do
    [[ -z "$d" || "$d" == \#* ]] && continue
    DOMAINS+=("$d")
done < <(prosodyctl mod_list_domains 2>/dev/null | grep -vF "$(hostname -f)")

FN_LOG INFO "Checking ${#DOMAINS[@]} domains..."

for domain in "${DOMAINS[@]}"; do
    score=$(calculate_score "$domain")
    if (( score >= SCORE_REQUIRED )); then
        expire=$((NOW + EXPIRY))
        BLACKLIST["$domain"]=$expire
        FN_LOG INFO "Blacklisted $domain (score=$score, until=$(date -d @$expire))"
    fi
done

# Lua
{
    echo "-- Generated on $(date)"
    echo "return {"
    for d in "${!BLACKLIST[@]}"; do
        echo "    [\"$d\"] = ${BLACKLIST[$d]},"
    done
    echo "}"
} > "$OUTPUT_LUA"

FN_LOG INFO "Blacklist updated → $OUTPUT_LUA"