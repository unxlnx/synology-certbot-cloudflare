# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A Docker container that automates Let's Encrypt certificate issuance and renewal via Certbot + the Cloudflare DNS-01 plugin, with optional deployment to Synology DSM. The entire runtime is two shell scripts — there is no application framework, package manager, or test suite.

## Common Commands

```bash
# Setup
cp config/.env.example config/.env   # then edit with real values

# Build and run locally
docker compose up -d
docker compose logs -f

# Build image directly
docker build -t synology-certbot-cloudflare .

# Force a cert renewal without restarting the container
# Edit config/.env and set FORCE_RENEW=true — the watcher picks it up within 10 seconds

# Trigger a domain change without restart
# Edit CERT_DOMAINS in config/.env and save
```

There are no lint or test commands — the scripts use `shellcheck` annotations inline (see `# shellcheck disable=` comments). To lint manually: `shellcheck entrypoint.sh deploy-hook.sh`.

## Architecture

All logic lives in two shell scripts copied into the image at `/scripts/`:

### `entrypoint.sh` — main runner
1. **Startup**: loads `config/.env`, validates required vars, writes `config/cloudflare.ini` (600 perms) from `CF_API_TOKEN`, logs versions and config summary, saves a domain snapshot to `/tmp/last_known_domains`.
2. **`.env` watcher** (`start_env_watcher`): runs in the background, polls every 10 s via `md5sum`. On change, reloads config, detects `FORCE_RENEW=true` or domain additions/removals, and writes a trigger file (`/tmp/cert_trigger` + `/tmp/cert_trigger_reason`).
3. **Main loop**: sleeps in 10 s increments up to `CHECK_INTERVAL_HOURS`. On each tick it checks for the trigger file; if present it calls `do_cert_check` with the stored reason immediately. After the sleep interval elapses it runs a scheduled check.
4. **`do_cert_check`**: reloads config, then either always calls `run_certbot` (for domain/force triggers) or calls `cert_needs_renewal` first (for scheduled checks). `cert_needs_renewal` uses `openssl x509 -checkend`. After any cert check, calls `ensure_synology_deployed` to retry any previously failed DSM upload.
5. **`run_certbot`**: selects `--expand` (domain added) or `--force-renewal` (domain removed, both, or force) flags, runs certbot with `--dns-cloudflare --key-type rsa`, resets `FORCE_RENEW=false` in `.env` via `sed -i` after success, then calls `deploy-hook.sh` directly (see note below).

### `deploy-hook.sh` — post-renewal deploy script
Called directly by `run_certbot` after every successful renewal (not via certbot's `--deploy-hook` — see Key Behaviours). When `SYNOLOGY_DEPLOY=true`:
1. Authenticates with DSM (`/webapi/auth.cgi`) requesting a `SynoToken` (`enable_syno_token=yes`)
2. Uploads `privkey.pem` / `cert.pem` / `chain.pem` via multipart POST to `/webapi/entry.cgi`, passing `SynoToken` as both a URL param and `X-SYNO-TOKEN` header (required for DSM CSRF protection)
3. Sets cert as default, then logs out
4. Writes deploy status (`SUCCESS` or `FAILED`) to `/config/.synology_deploy_status`

### Deploy status tracking
`/config/.synology_deploy_status` persists the result of the last Synology deploy attempt. `ensure_synology_deployed` reads this on every cert check and retries automatically if the status is not `SUCCESS`. Fields: `STATUS`, `TIMESTAMP`, `LINEAGE`, `DOMAINS`.

### Trigger mechanism
The watcher and main loop communicate through two temp files:
- `/tmp/cert_trigger` — presence signals a pending action
- `/tmp/cert_trigger_reason` — one of: `force_renew`, `domain_added`, `domain_removed`, `domain_both`

### `Dockerfile`
Alpine 3.23 base. Pip packages (`certbot`, `certbot-dns-cloudflare`) are installed from `requirements.txt` with pinned versions — managed by Renovate. System packages: `python3`, `inotify-tools`, `jq`, `openssl`, `bash`, `curl`, `tzdata`. No build arguments.

## CI/CD (`.github/workflows/build-and-publish.yml`)

Three sequential jobs:
1. **build** — amd64-only build, exports image tarball as artifact (multi-arch tarballs aren't supported by Docker)
2. **scan** — loads tarball, runs Trivy for CRITICAL/HIGH CVEs, uploads SARIF to GitHub Security tab
3. **publish** — full amd64 + arm64 build via QEMU emulation, pushes to GHCR (skipped on PRs)

Image is published to `ghcr.io/<owner>/synology-certbot-cloudflare`. Tags: semver (`1.2.3`, `1.2`, `1`, `latest`) on version tags; `main` + `sha-<short>` on branch pushes.

## Dependency Management (Renovate)

`renovate.json` configures Renovate bot (runs weekly, Monday before 6am):
- **certbot + certbot-dns-cloudflare** — grouped together (they always share the same version), tracked via `requirements.txt`
- **Alpine base image** — tracked in `Dockerfile`
- **GitHub Actions** — minor/patch updates auto-merged

## Key Behaviours to Know

- **No container restart needed** for config changes — the watcher detects `.env` modifications within ~10 seconds (debounced by 2 s).
- Always mount `./config:/config` as a **directory** (not file), or inotify-based editors that do atomic saves will break change detection.
- `cloudflare.ini` is generated at runtime from `CF_API_TOKEN` and is never baked into the image.
- `LETSENCRYPT_ENV=staging` uses `acme-staging-v02.api.letsencrypt.org`; `production` uses `acme-v02.api.letsencrypt.org`. Always start with staging.
- DNS propagation wait defaults to 30 seconds (`--dns-cloudflare-propagation-seconds 30` in `run_certbot`).
- Date parsing uses BusyBox `date -D` syntax — macOS BSD `date -j` is not compatible and will not work inside the container.
- **Certbot issues RSA certs** (`--key-type rsa`) — Synology DSM's certificate import API rejects ECDSA certs (error 5511). Do not remove this flag.
- **deploy-hook.sh is called directly** by `run_certbot`, not via certbot's `--deploy-hook`. This keeps log output consistent (certbot indents hook output with a leading space when it captures it).
