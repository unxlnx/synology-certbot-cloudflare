#!/usr/bin/env bash
# Called by certbot after a successful renewal.
# RENEWED_LINEAGE is set by certbot to the cert path e.g. /etc/letsencrypt/live/example.com

LOG_PREFIX="[synology-certbot-cloudflare:deploy-hook]"
SYNOLOGY_DEPLOY="${SYNOLOGY_DEPLOY:-false}"
DEPLOY_STATUS_FILE="/config/.synology_deploy_status"

echo "$LOG_PREFIX Cert renewed: $RENEWED_LINEAGE"

# ─── Status helpers ───────────────────────────────────────────────────────────
write_deploy_status() {
  local status="$1"
  local timestamp; timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  printf 'STATUS=%s\nTIMESTAMP=%s\nLINEAGE=%s\nDOMAINS=%s\n' \
    "$status" "$timestamp" "${RENEWED_LINEAGE:-unknown}" "${CERT_DOMAINS:-unknown}" \
    > "$DEPLOY_STATUS_FILE" 2>/dev/null \
    || echo "$LOG_PREFIX WARNING: could not write $DEPLOY_STATUS_FILE"
}

# ─── Synology DSM Deploy ──────────────────────────────────────────────────────
if [[ "$SYNOLOGY_DEPLOY" == "true" ]]; then
  echo "$LOG_PREFIX Deploying to Synology DSM at $SYNOLOGY_HOST..."

  if [[ -z "${SYNOLOGY_HOST:-}" || -z "${SYNOLOGY_USER:-}" || -z "${SYNOLOGY_PASS:-}" ]]; then
    echo "$LOG_PREFIX ERROR: SYNOLOGY_HOST, SYNOLOGY_USER, and SYNOLOGY_PASS must all be set" >&2
    write_deploy_status "FAILED"
    exit 0
  fi

  # Login and get session ID
  echo "$LOG_PREFIX Authenticating with DSM..."
  LOGIN_RESPONSE=$(curl -sk \
    "$SYNOLOGY_HOST/webapi/auth.cgi?api=SYNO.API.Auth&version=3&method=login&account=${SYNOLOGY_USER}&passwd=${SYNOLOGY_PASS}&session=synology-certbot-cloudflare&format=sid") || true

  SID=$(echo "$LOGIN_RESPONSE" | jq -r '.data.sid // empty')

  if [[ -z "$SID" ]]; then
    echo "$LOG_PREFIX ERROR: Failed to authenticate with Synology DSM — check SYNOLOGY_HOST, SYNOLOGY_USER, SYNOLOGY_PASS" >&2
    echo "$LOG_PREFIX Response: $LOGIN_RESPONSE" >&2
    write_deploy_status "FAILED"
    exit 0
  fi

  echo "$LOG_PREFIX Authenticated with DSM (session: ${SID:0:8}...)"

  # Upload certificate
  echo "$LOG_PREFIX Uploading certificate from $RENEWED_LINEAGE..."
  UPLOAD_RESPONSE=$(curl -sk -X POST "$SYNOLOGY_HOST/webapi/entry.cgi" \
    -F "api=SYNO.Core.Certificate" \
    -F "method=import" \
    -F "version=1" \
    -F "_sid=$SID" \
    -F "key=@${RENEWED_LINEAGE}/privkey.pem" \
    -F "certificate=@${RENEWED_LINEAGE}/cert.pem" \
    -F "intermediate=@${RENEWED_LINEAGE}/chain.pem" \
    -F "as_default=true") || true

  SUCCESS=$(echo "$UPLOAD_RESPONSE" | jq -r '.success // false')

  # Logout
  curl -sk "$SYNOLOGY_HOST/webapi/auth.cgi?api=SYNO.API.Auth&version=1&method=logout&session=synology-certbot-cloudflare&_sid=$SID" > /dev/null || true

  if [[ "$SUCCESS" != "true" ]]; then
    echo "$LOG_PREFIX ERROR: Failed to upload cert to Synology DSM" >&2
    echo "$LOG_PREFIX Response: $UPLOAD_RESPONSE" >&2
    write_deploy_status "FAILED"
    exit 0
  fi

  write_deploy_status "SUCCESS"
  echo "$LOG_PREFIX Successfully deployed cert to Synology DSM"
fi

echo "$LOG_PREFIX Deploy hook complete"
