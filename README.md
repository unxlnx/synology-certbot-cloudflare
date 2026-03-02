# synology-certbot-cloudflare

A lightweight, self-contained Docker container that automates Let's Encrypt certificate management using Certbot and the Cloudflare DNS plugin. Certificates are automatically obtained, monitored, and renewed — with optional deployment to Synology DSM.

---

## Features

- Automatic certificate issuance and renewal via Let's Encrypt
- Cloudflare DNS-01 challenge (supports wildcard certs)
- Staging and production modes to avoid rate limits during testing
- Configurable renewal check interval and expiry threshold
- Force renewal via `.env` flag — auto-resets after success
- Live `.env` monitoring via inotify — detects domain changes and triggers renewal without restarting the container
- Optional Synology DSM certificate deployment via API
- Timestamped logging for all output
- Multi-arch image build (amd64 + arm64)
- Automated CI/CD with GitHub Actions — builds, scans (Trivy), and publishes to GHCR

---

## Project Structure

```
synology-certbot-cloudflare/
├── .github/
│   └── workflows/
│       └── build-and-publish.yml   # CI/CD pipeline
├── config/
│   └── .env                        # Your configuration (never commit this)
├── Dockerfile
├── docker-compose.yml
├── entrypoint.sh                   # Main runner script
├── deploy-hook.sh                  # Called by certbot after successful renewal
├── .gitignore
└── README.md
```

---

## Quick Start

### 1. Clone the repository

```bash
git clone https://github.com/youruser/synology-certbot-cloudflare.git
cd synology-certbot-cloudflare
```

### 2. Create your config and `.env`

```bash
cp config/.env.example config/.env
```

Edit `config/.env` with your values (see [Configuration](#configuration) below).

### 3. Build and start

```bash
docker compose up -d
docker compose logs -f
```

---

## Configuration

All configuration lives in `config/.env`. The container watches this file for changes at runtime — no restart required when updating domains or toggling options.

```dotenv
# ── Let's Encrypt Environment ─────────────────────────────
# Options: staging | production
# Always start with staging to verify your setup before going live
LETSENCRYPT_ENV=staging

# ── Cloudflare ────────────────────────────────────────────
# API token with Zone:DNS:Edit permissions for your domain(s)
CF_API_TOKEN=your-cloudflare-api-token

# ── Certificate ───────────────────────────────────────────
# Comma-separated list of domains. Prefix with *. for wildcards.
CERT_DOMAINS=example.com,*.example.com
CERT_EMAIL=admin@example.com

# ── Renewal schedule ──────────────────────────────────────
# How often to check if renewal is needed (in hours)
CHECK_INTERVAL_HOURS=12
# Renew the cert if expiry is within this many days
RENEW_DAYS_BEFORE=30

# ── Force renewal ─────────────────────────────────────────
# Set to 'true' to force cert issuance/renewal on next check
# Automatically resets to 'false' after successful renewal
FORCE_RENEW=false

# ── Synology deploy ───────────────────────────────────────
SYNOLOGY_DEPLOY=false
SYNOLOGY_HOST=https://your-nas:5001
SYNOLOGY_USER=admin
SYNOLOGY_PASS=yourpassword

# ── Timezone ──────────────────────────────────────────────
TZ=America/New_York
```

### Cloudflare API Token

Create a scoped API token at https://dash.cloudflare.com/profile/api-tokens with the following permissions:

- **Zone / DNS / Edit** — for each zone you want to issue certs for
- **Zone / Zone / Read** — required for zone lookup

---

## Staging vs Production

Always test with `LETSENCRYPT_ENV=staging` first. The staging environment issues certificates that are not browser-trusted but lets you verify your DNS and Cloudflare setup without consuming production rate limits.

When you are ready to go live:

1. Set `LETSENCRYPT_ENV=production` in `config/.env`
2. Set `FORCE_RENEW=true` to replace the staging cert immediately
3. Save the file — the container detects the change and runs automatically

```dotenv
LETSENCRYPT_ENV=production
FORCE_RENEW=true
```

The container will issue a real trusted cert and auto-reset `FORCE_RENEW=false`.

---

## Adding or Removing Domains

Edit `CERT_DOMAINS` in `config/.env` and save. The inotify watcher detects the change, compares the new domain list against the last known snapshot, and automatically triggers a new cert covering all listed domains. No restart needed.

```dotenv
# Before
CERT_DOMAINS=example.com,*.example.com

# After — container detects the addition and cuts a new cert automatically
CERT_DOMAINS=example.com,*.example.com,other.example.com
```

---

## Force Renewal

Set `FORCE_RENEW=true` in `config/.env` and save. The container detects the change and immediately runs certbot with `--force-renewal`, regardless of the current cert's expiry. After a successful renewal `FORCE_RENEW` is automatically reset to `false`.

Use this when:
- Switching from staging to production
- Domains have changed
- A cert was corrupted or deleted
- You want to rotate a cert early

---

## Synology DSM Deployment

When `SYNOLOGY_DEPLOY=true`, the deploy hook calls the Synology DSM API after every successful renewal to upload the new cert and set it as the default.

Requirements:
- DSM user with administrator privileges
- HTTPS access to your NAS from the container (port 5001 by default)
- `jq` is included in the image — no extra setup needed

The deploy hook:
1. Authenticates with DSM to obtain a session ID
2. Uploads `privkey.pem`, `cert.pem`, and `chain.pem`
3. Sets the uploaded cert as the default
4. Logs out cleanly

---

## Volumes

| Volume | Purpose |
|---|---|
| `synology-certbot-cloudflare-certs` | Certificate files (`/etc/letsencrypt`) |
| `synology-certbot-cloudflare-data` | Certbot working data (`/var/lib/letsencrypt`) |
| `synology-certbot-cloudflare-logs` | Certbot logs (`/var/log/letsencrypt`) |
| `./config:/config` | Config directory — contains `.env` and generated `cloudflare.ini` |

Cert volumes are named Docker volumes and persist across container restarts and rebuilds.

---

## Logging

All output — including certbot's own output — is timestamped uniformly:

```
[2026-03-02 15:36:31] [synology-certbot-cloudflare] Versions:
[2026-03-02 15:36:31] [synology-certbot-cloudflare]   certbot          : certbot 2.11.0
[2026-03-02 15:36:31] [synology-certbot-cloudflare]   python           : Python 3.11.9
[2026-03-02 15:36:31] [synology-certbot-cloudflare]   dns-cloudflare   : certbot-dns-cloudflare 0.3.0
[2026-03-02 15:36:31] [synology-certbot-cloudflare] ════════════════════════════════════════
[2026-03-02 15:36:31] [synology-certbot-cloudflare]  synology-certbot-cloudflare starting
[2026-03-02 15:36:31] [synology-certbot-cloudflare]  Environment : production
[2026-03-02 15:36:31] [synology-certbot-cloudflare]  Domains     : example.com,*.example.com
[2026-03-02 15:36:31] [synology-certbot-cloudflare]  Check every : 12h
[2026-03-02 15:36:31] [synology-certbot-cloudflare]  Renew within: 30 days
[2026-03-02 15:36:31] [synology-certbot-cloudflare]  Synology    : false
[2026-03-02 15:36:31] [synology-certbot-cloudflare] ════════════════════════════════════════
[2026-03-02 15:36:32] [synology-certbot-cloudflare] Cert for example.com expires in 87 days (threshold: 30) — OK
[2026-03-02 15:36:32] [synology-certbot-cloudflare] Sleeping 12h until next check...
```

---

## CI/CD — GitHub Actions

The included workflow at `.github/workflows/build-and-publish.yml` runs on every push to `main` and on version tags.

**Jobs:**

1. **Build** — builds the image (amd64) and saves it as a workflow artifact for scanning
2. **Scan** — runs [Trivy](https://github.com/aquasecurity/trivy) against the image and uploads results to the GitHub Security tab (SARIF)
3. **Publish** — builds and pushes the full multi-arch image (amd64 + arm64) to GHCR (skipped on pull requests)

> **Note on multi-arch:** The scan job uses an amd64-only build since Docker image tarballs cannot represent multi-arch manifests. The publish job performs the full amd64 + arm64 build via QEMU emulation before pushing to GHCR.

**Image tags produced:**

| Trigger | Tags |
|---|---|
| Push to `main` | `main`, `sha-abc1234` |
| Tag `v1.2.3` | `1.2.3`, `1.2`, `1`, `latest`, `sha-abc1234` |
| Pull request | Build and scan only — no push |

**Pulling the image:**

```bash
docker pull ghcr.io/youruser/synology-certbot-cloudflare:latest
```

To use the pre-built image instead of building locally, replace the `build:` key in `docker-compose.yml`:

```yaml
services:
  synology-certbot-cloudflare:
    image: ghcr.io/unxlnx/synology-certbot-cloudflare:latest
```

---

## Security

- `cloudflare.ini` is written from `CF_API_TOKEN` at startup with `chmod 600` — it is never stored in the image
- The `config/.env` file should never be committed — it is listed in `.gitignore`
- Trivy scans run on every build and results are visible in the GitHub Security tab
- The container runs as root by default (required for certbot to write to `/etc/letsencrypt`). For hardened deployments, consider a named volume with appropriate permissions and a non-root user with `CAP_NET_BIND_SERVICE`

---

## Troubleshooting

**inotify not detecting `.env` changes**

Mount the config directory rather than the file directly. File-level bind mounts use inode watching which breaks when editors do atomic saves:

```yaml
# docker-compose.yml
volumes:
  - ./config:/config    # correct — mount the directory
```

**`date: unrecognized option: j`**

This is a macOS BSD date flag. The script uses `openssl x509 -checkend` and BusyBox-compatible `date -D` syntax — ensure you are running the latest version of the image.

**Certbot rate limit errors**

You have hit Let's Encrypt's production rate limits. Switch to `LETSENCRYPT_ENV=staging` to test, or wait for the rate limit window to reset (typically 1 week). See https://letsencrypt.org/docs/rate-limits/ for details.

**DNS propagation failures**

Increase `--dns-cloudflare-propagation-seconds` in `entrypoint.sh` if your DNS changes are slow to propagate. The default is 30 seconds.

---

## License

MIT
