# OpenClaw GCP Deployment (Automated + Public URL)

This repository provides an automated path to deploy OpenClaw on Google Cloud Platform, including optional public URL support through an `A` record and Caddy reverse proxy.

## What Is Included

- Interactive deployment script for end-to-end setup on GCP
- Docker Compose for OpenClaw Gateway + CLI
- Config templates (`.env.example`, `configs/openclaw.json`)
- Utility scripts for post-boot setup and custom skills deployment

## Prerequisites

- Google Cloud account
- `gcloud` CLI installed and authenticated (`gcloud auth login`)
- Project permissions for Compute Engine, IAM, and Cloud DNS (if DNS automation is used)
- A domain you control (for public URL)

## Quick Start (Recommended)

Run the interactive deployment script from this repository:

```bash
chmod +x ./scripts/deploy-gcp-interactive.sh
./scripts/deploy-gcp-interactive.sh
```

The script prompts for all required variables and automates:

1. Project/API setup (`compute`, `dns`, `aiplatform`)
2. Static external IP reservation
3. Firewall rule creation
4. VM creation (or reuse)
5. Remote Docker/OpenClaw bootstrap
6. Optional Cloud DNS `A` record automation
7. Optional Caddy reverse proxy with automatic HTTPS

## Model Providers Included

`configs/openclaw.json` is preconfigured with these providers:

- OpenRouter (`openrouter`)
- Gemini (`gemini`)
- Kimi for code (`kimi`, default primary model: `kimi-k2-0905-preview`)
- Groq (`groq`)

## Public URL via A Record

If public URL is enabled, the script asks for:

- `PUBLIC_URL_FQDN` (for example `openclaw.example.com`)
- Whether to auto-manage Cloud DNS record
- Whether to install Caddy for HTTPS reverse proxy

### DNS Modes

- Cloud DNS managed by script: script creates/updates the `A` record
- External DNS provider: script prints exact record to create manually

Manual DNS record format:

- Type: `A`
- Host: `<your-subdomain>`
- Value: `<vm-static-external-ip>`
- TTL: `300` (or your preferred value)

## Runtime Configuration

Key environment variables are stored in `.env` on the VM deployment directory.

Main values:

- `OPENCLAW_GATEWAY_TOKEN`
- `OPENCLAW_CONFIG_DIR`
- `OPENCLAW_WORKSPACE_DIR`
- `OPENROUTER_API_KEY` / `OPENROUTER_BASE_URL`
- `GEMINI_API_KEY` / `GEMINI_BASE_URL`
- `KIMI_API_KEY` / `KIMI_BASE_URL`
- `GROQ_API_KEY` / `GROQ_BASE_URL`
- `OPENCLAW_GATEWAY_PORT`
- `OPENCLAW_GATEWAY_HOST_BIND`
- `PUBLIC_URL_FQDN`

Reference templates:

- `.env.example`
- `configs/env.template`

## Manual Deployment (If Needed)

If you prefer not to use the interactive script:

1. Create a Debian 12 VM with `cloud-platform` scope.
2. Reserve and attach a static external IP.
3. Open inbound firewall ports `22`, `80`, `443`, and gateway port (`18789` by default).
4. Clone this repository on the VM.
5. Create `.env` from `.env.example`.
6. Copy `configs/openclaw.json` to `${OPENCLAW_CONFIG_DIR}/openclaw.json`.
7. Start services:

```bash
sudo docker compose up -d
```

8. (Optional) Install Caddy and reverse proxy your domain to `127.0.0.1:18789`.

## Multi-Agent Configuration Example

`configs/openclaw.json` includes a multi-agent setup:

- `main` (default)
- `lena`
- `marcus`

Telegram bindings and custom commands are already included and can be customized per bot token.

## Useful Commands

```bash
# SSH into VM
gcloud compute ssh <VM_NAME> --zone=<ZONE>

# Gateway logs
sudo docker logs openclaw-openclaw-gateway-1 --since 10m

# Run gateway security audit inside container
sudo docker compose exec openclaw-gateway openclaw security audit

# Restart gateway
sudo docker compose restart openclaw-gateway

# Re-deploy custom skills into container
./scripts/deploy_custom_skills.sh

# Post-reboot container/tool bootstrap on VM
./scripts/setup-openclaw.sh
```

## Troubleshooting

| Issue | Fix |
|---|---|
| `ACCESS_TOKEN_SCOPE_INSUFFICIENT` | VM must use `cloud-platform` scope |
| Public URL not reachable | Verify firewall + DNS `A` record points to VM static IP |
| HTTPS cert not issued | Ensure DNS is propagated and ports `80/443` are open |
| `Unknown model` | Use model IDs from your configured provider in `configs/openclaw.json` |
| Telegram bot does not respond | Check bot token, channel config, and container logs |

## Security Notes

- Keep `.env` and API keys private.
- Restrict gateway exposure with `OPENCLAW_GATEWAY_HOST_BIND=127.0.0.1` when using Caddy.
- Prefer HTTPS public access through Caddy instead of exposing raw gateway port.

## Files You Will Most Likely Edit

- `scripts/deploy-gcp-interactive.sh`
- `.env.example`
- `configs/env.template`
- `configs/openclaw.json`
- `docker-compose.yml`
