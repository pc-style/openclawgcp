# AGENTS.md - OpenClaw GCP Deployment

## Project Type
Infrastructure/ops repo for deploying **OpenClaw** (AI assistant gateway) on GCP. No build/test/lint pipeline -- this is shell scripts, Docker Compose, and JSON configs.

## Key Commands
- `./scripts/deploy-gcp-interactive.sh` -- Full interactive GCP deployment (VM, firewall, DNS, Caddy)
- `./scripts/deploy_custom_skills.sh` -- Push skills into the running container
- `./scripts/setup-openclaw.sh` -- Post-reboot bootstrap on the VM
- `docker compose up -d` / `docker compose restart` -- Manage services on the VM
- `gcloud compute ssh openclaw-gateway --zone=us-central1-a` -- SSH into VM

## Architecture
Three Docker services (`docker-compose.yml`): **openclaw-gateway** (Node.js, port 18789), **redis** (state/queue, port 6379), **playwright** (headless browser). Gateway exposes port 3000 mapped to host 18789. Redis uses AOF persistence. Configs live in `~/.openclaw/` on VM.

## Directory Structure
- `scripts/` -- Bash deployment and setup scripts (use `snake_case` or `kebab-case` naming)
- `configs/` -- JSON config (`openclaw.json`, `config.json`), env template, agent personas, `HEARTBEAT.md` (cron workflows), `MEMORY.md` (learned context)
- `skills/` -- Custom OpenClaw skills (mcp-client, camoufox, imgur-upload, r2-upload)
- `SOUL.md` -- Agent personality and platform access instructions
- `HANDOFF.md` -- Deployment state, infra details, pending actions

## Conventions
- Shell scripts: Bash, `chmod +x`, no tests -- validate manually
- Secrets in `.env` (never commit); reference `.env.example` for required keys
- LLM providers configured in `configs/openclaw.json` (OpenRouter, Gemini, Kimi, Groq)
- VM: Debian 12, `e2-small`, region `us-central1-a`, project `central-point-477516-v8`
- Always use `gcloud` CLI for GCP operations; `docker compose` (v2 syntax) for services
