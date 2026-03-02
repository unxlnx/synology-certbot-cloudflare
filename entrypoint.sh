#!/usr/bin/env bash
set -euo pipefail

# ─── Timestamp all output ─────────────────────────────────────────────────────
if [[ -z "${LOGGING_INIT:-}" ]]; then
  export LOGGING_INIT=1
  exec 2>&1
  exec bash "$0" "$@" | awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), $0; fflush() }'
  exit $?
fi

LOG_PREFIX="[synology-certbot-cloudflare]"
TRIGGER_FILE="/tmp/cert_trigger"
TRIGGER_REASON_FILE="/tmp/cert_trigger_reason"
DOMAINS_SNAPSHOT="/tmp/last_known_domains"
ENV_FILE="/config/.env"

# ─── Load / reload config from .env ──────────────────────────────────────────
load_config() {
  if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
  fi

  CHECK_INTERVAL_HOURS="${CHECK_INTERVAL_HOURS:-12}"
  RENEW_DAYS_BEFORE="${RENEW_DAYS_BEFORE:-30}"
  CERT_DOMAINS="${CERT_DOMAINS:-}"
  CERT_EMAIL="${CERT_EMAIL:-}"
  CF_API_TOKEN="${CF_API_TOKEN:-}"
  SYNOLOGY_DEPLOY="${SYNOLOGY_DEPLOY:-false}"
  LETSENCRYPT_ENV="${LETSENCRYPT_ENV:-staging}"
  FORCE_RENEW="${FORCE_RENEW:-false}"
}

# ─── Validation ──────────────────────────────────────────────────────────────
validate_config() {
  local errors=0

  if [[ -z "$CERT_DOMAINS" ]]; then
    echo "$LOG_PREFIX ERROR: CERT_DOMAINS is not set" >&2
    errors=$(( errors + 1 ))
  fi
  if [[ -z "$CERT_EMAIL" ]]; then
    echo "$LOG_PREFIX ERROR: CERT_EMAIL is not set" >&2
    errors=$(( errors + 1 ))
  fi
  if [[ -z "$CF_API_TOKEN" ]]; then
    echo "$LOG_PREFIX ERROR: CF_API_TOKEN is not set" >&2
    errors=$(( errors + 1 ))
  fi
  if [[ "$LETSENCRYPT_ENV" != "staging" && "$LETSENCRYPT_ENV" != "production" ]]; then
    echo "$LOG_PREFIX ERROR: LETSENCRYPT_ENV must be 'staging' or 'production' (got: '$LETSENCRYPT_ENV')" >&2
    errors=$(( errors + 1 ))
  fi

  if [[ $errors -gt 0 ]]; then
    return 1
  fi

  if [[ "$LETSENCRYPT_ENV" == "staging" ]]; then
    ACME_SERVER="https://acme-staging-v02.api.letsencrypt.org/directory"
    echo "$LOG_PREFIX ⚠️  STAGING MODE — certs will not be browser-trusted"
  else
    ACME_SERVER="https://acme-v02.api.letsencrypt.org/directory"
    echo "$LOG_PREFIX ✅ PRODUCTION MODE — issuing real trusted certs"
  fi
}

# ─── Write Cloudflare credentials ────────────────────────────────────────────
write_cf_ini() {
  local CF_INI="/config/cloudflare.ini"
  mkdir -p /config
  cat > "$CF_INI" <<EOF
dns_cloudflare_api_token = ${CF_API_TOKEN}
EOF
  chmod 600 "$CF_INI"
}

# ─── Domain helpers ──────────────────────────────────────────────────────────
normalize_domains() {
  echo "$1" | tr ',' '\n' | xargs -I{} echo "{}" | sort
}

get_primary_domain() {
  IFS=',' read -ra DOMAIN_LIST <<< "$CERT_DOMAINS"
  echo "${DOMAIN_LIST[0]}" | xargs | sed 's/^\*\.//'
}

build_domain_args() {
  local args=""
  IFS=',' read -ra DOMAIN_LIST <<< "$CERT_DOMAINS"
  for domain in "${DOMAIN_LIST[@]}"; do
    domain=$(echo "$domain" | xargs)
    args="$args -d $domain"
  done
  echo "$args"
}

# ─── Domain snapshot ─────────────────────────────────────────────────────────
save_domain_snapshot() {
  normalize_domains "$CERT_DOMAINS" > "$DOMAINS_SNAPSHOT"
  echo "$LOG_PREFIX Domain snapshot saved: $(cat $DOMAINS_SNAPSHOT | tr '\n' ' ')"
}

domains_changed() {
  if [[ ! -f "$DOMAINS_SNAPSHOT" ]]; then
    echo "$LOG_PREFIX No domain snapshot found — treating as changed"
    return 0
  fi

  local current
  current=$(normalize_domains "$CERT_DOMAINS")
  local previous
  previous=$(cat "$DOMAINS_SNAPSHOT")

  if [[ "$current" != "$previous" ]]; then
    local added
    added=$(comm -23 <(echo "$current") <(echo "$previous") | tr '\n' ' ')
    local removed
    removed=$(comm -13 <(echo "$current") <(echo "$previous") | tr '\n' ' ')

    [[ -n "$added" ]]   && echo "$LOG_PREFIX New domains detected: $added"
    [[ -n "$removed" ]] && echo "$LOG_PREFIX Removed domains detected: $removed"
    return 0
  fi

  return 1
}

# ─── Trigger helpers ─────────────────────────────────────────────────────────
set_trigger() {
  echo "$1" > "$TRIGGER_REASON_FILE"
  touch "$TRIGGER_FILE"
}

clear_trigger() {
  rm -f "$TRIGGER_FILE" "$TRIGGER_REASON_FILE"
}

get_trigger_reason() {
  cat "$TRIGGER_REASON_FILE" 2>/dev/null || echo "unknown"
}

# ─── Cert renewal check ──────────────────────────────────────────────────────
cert_needs_renewal() {
  local primary_domain
  primary_domain=$(get_primary_domain)
  local cert_path="/etc/letsencrypt/live/${primary_domain}/fullchain.pem"

  if [[ "$FORCE_RENEW" == "true" ]]; then
    echo "$LOG_PREFIX FORCE_RENEW=true — forcing renewal"
    return 0
  fi

  if [[ ! -f "$cert_path" ]]; then
    echo "$LOG_PREFIX No existing cert found for $primary_domain — will obtain"
    return 0
  fi

  # Use openssl -checkend to avoid date parsing entirely
  local threshold_seconds
  threshold_seconds=$(( RENEW_DAYS_BEFORE * 86400 ))

  if ! openssl x509 -checkend "$threshold_seconds" -noout -in "$cert_path" > /dev/null 2>&1; then
    local expiry_str
    expiry_str=$(openssl x509 -enddate -noout -in "$cert_path" | cut -d= -f2)
    local expiry_epoch
    expiry_epoch=$(date -D "%b %d %T %Y" -d "${expiry_str% GMT}" +%s 2>/dev/null || echo "0")
    local now_epoch
    now_epoch=$(date +%s)
    local days_until_expiry
    days_until_expiry=$(( (expiry_epoch - now_epoch) / 86400 ))

    echo "$LOG_PREFIX Cert for $primary_domain expires in $days_until_expiry days (threshold: $RENEW_DAYS_BEFORE) — renewing"
    return 0
  fi

  local expiry_str
  expiry_str=$(openssl x509 -enddate -noout -in "$cert_path" | cut -d= -f2)
  local expiry_epoch
  expiry_epoch=$(date -D "%b %d %T %Y" -d "${expiry_str% GMT}" +%s 2>/dev/null || echo "0")
  local now_epoch
  now_epoch=$(date +%s)
  local days_until_expiry
  days_until_expiry=$(( (expiry_epoch - now_epoch) / 86400 ))

  echo "$LOG_PREFIX Cert for $primary_domain expires in $days_until_expiry days (threshold: $RENEW_DAYS_BEFORE) — OK"
  return 1
}

# ─── Run certbot ─────────────────────────────────────────────────────────────
run_certbot() {
  local CF_INI="/config/cloudflare.ini"
  local domain_args
  domain_args=$(build_domain_args)

  local force_flag=""
  if [[ "$FORCE_RENEW" == "true" ]]; then
    force_flag="--force-renewal"
  fi

  echo "$LOG_PREFIX Running certbot against: $ACME_SERVER"

  # shellcheck disable=SC2086
  certbot certonly \
    --non-interactive \
    --agree-tos \
    --email "$CERT_EMAIL" \
    --dns-cloudflare \
    --dns-cloudflare-credentials "$CF_INI" \
    --dns-cloudflare-propagation-seconds 30 \
    --server "$ACME_SERVER" \
    --deploy-hook /scripts/deploy-hook.sh \
    $force_flag \
    $domain_args \
    2>&1

  local exit_code=${PIPESTATUS[0]}
  if [[ $exit_code -ne 0 ]]; then
    echo "$LOG_PREFIX ERROR: certbot exited with code $exit_code"
    return $exit_code
  fi

  echo "$LOG_PREFIX Certbot completed successfully"

  if [[ "$FORCE_RENEW" == "true" ]]; then
    echo "$LOG_PREFIX Resetting FORCE_RENEW=false in .env"
    sed -i 's/^FORCE_RENEW=true/FORCE_RENEW=false/' "$ENV_FILE" 2>/dev/null \
      || echo "$LOG_PREFIX WARNING: Could not reset FORCE_RENEW — reset manually"
    FORCE_RENEW="false"
  fi

  save_domain_snapshot
}

# ─── inotify watcher ─────────────────────────────────────────────────────────
start_env_watcher() {
  echo "$LOG_PREFIX Starting inotify watcher on $ENV_FILE"

  inotifywait -m -e close_write,modify,create,moved_to "$(dirname $ENV_FILE)" 2>/dev/null \
  | while read -r dir event file; do
      # Only act on .env changes
      if [[ "$file" != ".env" ]]; then
        continue
      fi

      echo "$LOG_PREFIX .env changed (event: $event) — reloading config"

      # Debounce — editors fire multiple events on a single save
      sleep 2

      load_config

      if ! validate_config 2>/dev/null; then
        echo "$LOG_PREFIX .env reload failed validation — ignoring change"
        continue
      fi

      write_cf_ini

      if [[ "$FORCE_RENEW" == "true" ]]; then
        echo "$LOG_PREFIX FORCE_RENEW detected in .env change"
        set_trigger "force_renew"
      elif domains_changed; then
        echo "$LOG_PREFIX Domain change detected — triggering cert renewal"
        set_trigger "domain_change"
      else
        echo "$LOG_PREFIX .env changed but no actionable cert change detected"
      fi
    done
}

# ─── Main cert check ─────────────────────────────────────────────────────────
do_cert_check() {
  local reason="${1:-scheduled}"
  echo "$LOG_PREFIX ─── Cert check triggered by: $reason at $(date) ───"

  load_config
  validate_config || { echo "$LOG_PREFIX Skipping cert check — config invalid"; return; }
  write_cf_ini

  if [[ "$reason" == "domain_change" || "$reason" == "force_renew" ]]; then
    run_certbot
  elif cert_needs_renewal; then
    run_certbot
  else
    echo "$LOG_PREFIX Cert is valid — no action needed"
  fi
}

# ─── Log versions ─────────────────────────────────────────────────────────────
log_versions() {
  local certbot_version
  certbot_version=$(certbot --version 2>&1)
  local python_version
  python_version=$(python3 --version 2>&1)
  local plugin_version
  plugin_version=$(pip3 show certbot-dns-cloudflare 2>/dev/null | awk '/^Version:/ { print $2 }')

  echo "$LOG_PREFIX Versions:"
  echo "$LOG_PREFIX   certbot          : $certbot_version"
  echo "$LOG_PREFIX   python           : $python_version"
  echo "$LOG_PREFIX   dns-cloudflare   : certbot-dns-cloudflare $plugin_version"
}

# ─── Startup ─────────────────────────────────────────────────────────────────
load_config
validate_config || exit 1
write_cf_ini

log_versions

echo "$LOG_PREFIX ════════════════════════════════════════"
echo "$LOG_PREFIX  synology-certbot-cloudflare starting"
echo "$LOG_PREFIX  Environment : $LETSENCRYPT_ENV"
echo "$LOG_PREFIX  Domains     : $CERT_DOMAINS"
echo "$LOG_PREFIX  Check every : ${CHECK_INTERVAL_HOURS}h"
echo "$LOG_PREFIX  Renew within: ${RENEW_DAYS_BEFORE} days"
echo "$LOG_PREFIX  Synology    : $SYNOLOGY_DEPLOY"
echo "$LOG_PREFIX ════════════════════════════════════════"

save_domain_snapshot

# Start inotify watcher in background
start_env_watcher &
WATCHER_PID=$!

# Clean shutdown
trap 'echo "$LOG_PREFIX Shutting down..."; kill "$WATCHER_PID" 2>/dev/null; exit 0' SIGTERM SIGINT

# Initial cert check at startup
do_cert_check "startup"
clear_trigger

# ─── Main loop ───────────────────────────────────────────────────────────────
SLEEP_SECONDS=$(( CHECK_INTERVAL_HOURS * 3600 ))

while true; do
  elapsed=0
  while [[ $elapsed -lt $SLEEP_SECONDS ]]; do
    sleep 10
    elapsed=$(( elapsed + 10 ))

    if [[ -f "$TRIGGER_FILE" ]]; then
      reason=$(get_trigger_reason)
      clear_trigger
      do_cert_check "$reason"
      elapsed=0
    fi
  done

  do_cert_check "scheduled"
done
