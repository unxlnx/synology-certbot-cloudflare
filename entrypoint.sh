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
DEPLOY_STATUS_FILE="/config/.synology_deploy_status"

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

# ─── Domain change detection ──────────────────────────────────────────────────
# Returns: "added", "removed", "both", or "none"
get_domain_change_type() {
  if [[ ! -f "$DOMAINS_SNAPSHOT" ]]; then
    echo "added"
    return
  fi

  local current
  current=$(normalize_domains "$CERT_DOMAINS")
  local previous
  previous=$(cat "$DOMAINS_SNAPSHOT")

  if [[ "$current" == "$previous" ]]; then
    echo "none"
    return
  fi

  local added
  added=$(comm -23 <(echo "$current") <(echo "$previous") | tr '\n' ' ' | xargs)
  local removed
  removed=$(comm -13 <(echo "$current") <(echo "$previous") | tr '\n' ' ' | xargs)

  if [[ -n "$added" && -n "$removed" ]]; then
    echo "both"
  elif [[ -n "$added" ]]; then
    echo "added"
  elif [[ -n "$removed" ]]; then
    echo "removed"
  else
    echo "none"
  fi
}

# ─── Log domain changes ───────────────────────────────────────────────────────
log_domain_changes() {
  if [[ ! -f "$DOMAINS_SNAPSHOT" ]]; then
    return 0
  fi

  local current
  current=$(normalize_domains "$CERT_DOMAINS")
  local previous
  previous=$(cat "$DOMAINS_SNAPSHOT")

  local added
  added=$(comm -23 <(echo "$current") <(echo "$previous") | tr '\n' ' ' | xargs)
  local removed
  removed=$(comm -13 <(echo "$current") <(echo "$previous") | tr '\n' ' ' | xargs)

  [[ -n "$added" ]]   && echo "$LOG_PREFIX   Added   : $added"
  [[ -n "$removed" ]] && echo "$LOG_PREFIX   Removed : $removed"
  return 0
}

# ─── Trigger helpers ─────────────────────────────────────────────────────────
set_trigger() {
  local reason="$1"
  echo "$LOG_PREFIX Writing trigger: $reason"
  echo "$reason" > "$TRIGGER_REASON_FILE" || { echo "$LOG_PREFIX ERROR: could not write $TRIGGER_REASON_FILE" >&2; return 1; }
  touch "$TRIGGER_FILE" || { echo "$LOG_PREFIX ERROR: could not write $TRIGGER_FILE" >&2; return 1; }
  echo "$LOG_PREFIX Trigger set OK — main loop will pick up within 10 seconds"
}

clear_trigger() {
  rm -f "$TRIGGER_FILE" "$TRIGGER_REASON_FILE"
}

get_trigger_reason() {
  cat "$TRIGGER_REASON_FILE" 2>/dev/null || echo "unknown"
}

# ─── Synology deploy status ───────────────────────────────────────────────────
get_deploy_status_field() {
  local field="$1"
  grep "^${field}=" "$DEPLOY_STATUS_FILE" 2>/dev/null | cut -d= -f2-
}

retry_synology_deploy() {
  local primary_domain lineage
  primary_domain=$(get_primary_domain)
  lineage="/etc/letsencrypt/live/${primary_domain}"

  if [[ ! -f "${lineage}/fullchain.pem" ]]; then
    echo "$LOG_PREFIX No cert found at $lineage — skipping Synology deploy retry"
    return 0
  fi

  echo "$LOG_PREFIX Retrying Synology DSM upload for $lineage (domains: $CERT_DOMAINS)..."
  RENEWED_LINEAGE="$lineage" /scripts/deploy-hook.sh \
    || echo "$LOG_PREFIX WARNING: deploy-hook returned non-zero (unexpected)"
}

ensure_synology_deployed() {
  if [[ "$SYNOLOGY_DEPLOY" != "true" ]]; then
    return 0
  fi

  local primary_domain lineage
  primary_domain=$(get_primary_domain)
  lineage="/etc/letsencrypt/live/${primary_domain}"

  if [[ ! -f "${lineage}/fullchain.pem" ]]; then
    echo "$LOG_PREFIX SYNOLOGY_DEPLOY=true but no cert exists yet — will deploy after first issuance"
    return 0
  fi

  if [[ ! -f "$DEPLOY_STATUS_FILE" ]]; then
    echo "$LOG_PREFIX Synology deploy status file not found — attempting deploy"
    retry_synology_deploy
    return 0
  fi

  local stored_status stored_domains
  stored_status=$(get_deploy_status_field "STATUS")
  stored_domains=$(get_deploy_status_field "DOMAINS")

  if [[ "$stored_status" != "SUCCESS" ]]; then
    echo "$LOG_PREFIX Previous Synology deploy status: ${stored_status:-unknown} — retrying"
    retry_synology_deploy
    return 0
  fi

  local current_norm stored_norm
  current_norm=$(normalize_domains "$CERT_DOMAINS")
  stored_norm=$(normalize_domains "$stored_domains")

  if [[ "$current_norm" != "$stored_norm" ]]; then
    echo "$LOG_PREFIX Domains changed since last Synology deploy"
    echo "$LOG_PREFIX   Was: $stored_domains"
    echo "$LOG_PREFIX   Now: $CERT_DOMAINS"
    retry_synology_deploy
    return 0
  fi

  echo "$LOG_PREFIX Synology deploy up to date (last deployed: $(get_deploy_status_field "TIMESTAMP"))"
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
  local expand_flag=""

  case "${CERT_TRIGGER_REASON:-}" in
    domain_added)
      expand_flag="--expand"
      echo "$LOG_PREFIX Using --expand (domains added)"
      ;;
    domain_removed)
      force_flag="--force-renewal"
      echo "$LOG_PREFIX Using --force-renewal (domains removed)"
      ;;
    domain_both)
      force_flag="--force-renewal"
      echo "$LOG_PREFIX Using --force-renewal (domains added and removed)"
      ;;
    force_renew)
      force_flag="--force-renewal"
      echo "$LOG_PREFIX Using --force-renewal (FORCE_RENEW requested)"
      ;;
    *)
      ;;
  esac

  if [[ "$FORCE_RENEW" == "true" && -z "$force_flag" ]]; then
    force_flag="--force-renewal"
    echo "$LOG_PREFIX Using --force-renewal (FORCE_RENEW=true)"
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
    --key-type rsa \
    $force_flag \
    $expand_flag \
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

# ─── .env watcher (polling) ───────────────────────────────────────────────────
handle_env_change() {
  # Runs with set -e disabled so nothing silently kills the watcher
  set +e

  load_config

  if ! validate_config; then
    echo "$LOG_PREFIX .env reload failed validation — ignoring change"
    set -e
    return 0
  fi

  write_cf_ini

  if [[ "$FORCE_RENEW" == "true" ]]; then
    echo "$LOG_PREFIX FORCE_RENEW=true detected"
    set_trigger "force_renew"
    set -e
    return 0
  fi

  local change_type
  change_type=$(get_domain_change_type)
  echo "$LOG_PREFIX Domain change type: $change_type"

  case "$change_type" in
    added)
      echo "$LOG_PREFIX Domain change detected (added):"
      log_domain_changes
      set_trigger "domain_added"
      ;;
    removed)
      echo "$LOG_PREFIX Domain change detected (removed):"
      log_domain_changes
      set_trigger "domain_removed"
      ;;
    both)
      echo "$LOG_PREFIX Domain change detected (added and removed):"
      log_domain_changes
      set_trigger "domain_both"
      ;;
    none)
      echo "$LOG_PREFIX .env changed but no domain or force-renew change detected"
      ;;
  esac

  set -e
  return 0
}

start_env_watcher() {
  echo "$LOG_PREFIX Starting .env file watcher (polling mode)"

  local last_checksum
  last_checksum=$(md5sum "$ENV_FILE" 2>/dev/null | awk '{print $1}' || echo "none")

  while true; do
    sleep 10

    local current_checksum
    current_checksum=$(md5sum "$ENV_FILE" 2>/dev/null | awk '{print $1}' || echo "none")

    if [[ "$current_checksum" != "$last_checksum" ]]; then
      echo "$LOG_PREFIX .env changed — reloading config"
      last_checksum="$current_checksum"

      # Debounce
      sleep 2

      handle_env_change || echo "$LOG_PREFIX WARNING: handle_env_change failed — watcher continuing"
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

  export CERT_TRIGGER_REASON="$reason"

  case "$reason" in
    domain_added|domain_removed|domain_both|force_renew)
      run_certbot
      ;;
    *)
      if cert_needs_renewal; then
        run_certbot
      else
        echo "$LOG_PREFIX Cert is valid — no action needed"
      fi
      ;;
  esac

  unset CERT_TRIGGER_REASON

  ensure_synology_deployed
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

# Start .env watcher in background
start_env_watcher &
WATCHER_PID=$!

# Clean shutdown
trap 'echo "$LOG_PREFIX Shutting down..."; kill "$WATCHER_PID" 2>/dev/null; exit 0' SIGTERM SIGINT

# Initial cert check at startup
do_cert_check "startup"

# Only clear trigger if watcher did not set one during startup cert check
if [[ -f "$TRIGGER_FILE" ]]; then
  echo "$LOG_PREFIX Trigger was set during startup check — preserving for main loop"
else
  clear_trigger
fi

# ─── Main loop ───────────────────────────────────────────────────────────────
SLEEP_SECONDS=$(( CHECK_INTERVAL_HOURS * 3600 ))

while true; do
  elapsed=0
  while [[ $elapsed -lt $SLEEP_SECONDS ]]; do
    sleep 10
    elapsed=$(( elapsed + 10 ))

    if [[ -f "$TRIGGER_FILE" ]]; then
      reason=$(get_trigger_reason)
      echo "$LOG_PREFIX Trigger file found: $reason"
      clear_trigger
      do_cert_check "$reason"
      elapsed=0
    fi
  done

  do_cert_check "scheduled"
done