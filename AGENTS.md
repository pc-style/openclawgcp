# AGENTS.md - OpenClaw GCP Deployment

## Project Overview

This is an infrastructure/operations repository for deploying **OpenClaw**—an AI assistant gateway—on Google Cloud Platform (GCP). It provides automated deployment scripts, Docker Compose configuration, and custom skills for running a multi-agent AI system with Telegram integration.

The project deploys a containerized stack consisting of:
- **OpenClaw Gateway**: Node.js-based AI gateway (main application)
- **Redis**: State management and queue persistence
- **Playwright**: Headless browser automation service

## Technology Stack

| Component | Technology |
|-----------|------------|
| Orchestration | Docker Compose |
| Cloud Platform | Google Cloud Platform (GCP) |
| VM OS | Debian 12 |
| State Store | Redis 7 (AOF persistence) |
| Browser Automation | Playwright (Chromium) |
| Reverse Proxy | Caddy (optional, with auto HTTPS) |
| Scripting | Bash |

## Project Structure

```
gcp-oc/
├── scripts/                    # Deployment and utility scripts
│   ├── deploy-gcp-interactive.sh    # Main GCP deployment script (interactive)
│   ├── setup-openclaw.sh            # Post-reboot VM bootstrap
│   ├── deploy_custom_skills.sh      # Deploy skills into running container
│   ├── setup-camoufox.sh            # Camoufox browser setup
│   └── openclaw-config.sh           # Configuration helper
├── configs/                    # Configuration files
│   ├── openclaw.json               # Main OpenClaw configuration
│   ├── config.json                 # Additional channel configs
│   ├── env.template                # Environment template
│   ├── agents/                     # Agent persona definitions (YAML)
│   │   ├── main-agent.yaml
│   │   └── lena-agent.yaml
│   ├── HEARTBEAT.md                # Scheduled workflow definitions
│   └── MEMORY.md                   # Persistent user context
├── skills/                     # Custom OpenClaw skills
│   ├── mcp-client/                 # MCP server client
│   ├── r2-upload/                  # Cloudflare R2 uploader
│   ├── imgur-upload/               # Imgur image uploader
│   └── camoufox/                   # Anti-detect browser
├── examples/                   # Reference configurations
│   ├── openclaw-config/            # Example configs from upstream
│   └── THIS-COULD-HELP/            # Local deployment examples
├── docker-compose.yml          # Service definitions
├── .env.example               # Required environment variables template
├── SOUL.md                    # Agent personality guidelines
└── HANDOFF.md                 # Current issues and deployment state
```

## Architecture

### Docker Services

| Service | Image | Port | Purpose | Resources |
|---------|-------|------|---------|-----------|
| `openclaw` | `openclaw:chromium` | 18789 | AI Gateway | 2 CPUs, 6GB RAM |
| `redis` | `redis:7-alpine` | 6379 | State/Queue | 512MB RAM, LRU eviction |
| `playwright` | `mcr.microsoft.com/playwright` | - | Browser automation | 1 CPU, 2GB RAM, 2GB shm |

### Network Flow

```
Internet → GCP Firewall → VM → Caddy (443) → OpenClaw (18789)
                                      ↓
                              Redis (6379) + Playwright
```

### Multi-Agent Configuration

The system supports multiple AI agents with different specializations:

| Agent | Model | Purpose |
|-------|-------|---------|
| `main` (Javis) | Gemini 3 Flash Preview | Default general-purpose agent |
| `lena` | Gemini 2.5 Pro | Image processing specialist |
| `marcus` | Groq GPT-OSS 120B | Fast inference (optional) |

## Key Commands

### Deployment & VM Management

```bash
# Full interactive GCP deployment
./scripts/deploy-gcp-interactive.sh

# SSH into VM
gcloud compute ssh openclaw-gateway --zone=us-central1-a

# Copy file to VM
gcloud compute scp file.txt openclaw-gateway:~/ --zone=us-central1-a
```

### Docker Compose (run on VM)

```bash
# Start all services
docker compose up -d

# Restart services
docker compose restart
docker compose restart openclaw

# View logs
docker compose logs -f openclaw
docker compose logs openclaw --tail 100

# Shell into container
docker compose exec openclaw bash

# Security audit
docker compose exec openclaw-gateway openclaw security audit
```

### Custom Skills

```bash
# Deploy skills after container recreation
./scripts/deploy_custom_skills.sh

# Post-reboot setup
./scripts/setup-openclaw.sh
```

## Environment Variables

Create `.env` from `.env.example` (never commit `.env`):

| Variable | Required | Description |
|----------|----------|-------------|
| `OPENCLAW_GATEWAY_TOKEN` | Yes | Auth token for gateway access |
| `OPENCLAW_CONFIG_DIR` | Yes | Config directory path (e.g., `/home/user/.openclaw`) |
| `OPENCLAW_WORKSPACE_DIR` | Yes | Workspace directory path |
| `OPENROUTER_API_KEY` | Yes | OpenRouter LLM provider key |
| `GEMINI_API_KEY` | Yes | Google Gemini API key |
| `KIMI_API_KEY` | Yes | Kimi/Moonshot API key |
| `GROQ_API_KEY` | No | Groq API key (optional) |
| `R2_ACCESS_KEY_ID` | No | Cloudflare R2 access key |
| `R2_SECRET_ACCESS_KEY` | No | Cloudflare R2 secret key |
| `KEOTHOM_MCP_API_KEY` | No | MCP server authentication |
| `PUBLIC_URL_FQDN` | No | Public domain (e.g., `openclaw.example.com`) |

## Configuration Files

### Main Config: `configs/openclaw.json`

Key sections:
- `models.providers`: LLM provider configurations (OpenRouter, Gemini, Kimi, Groq)
- `agents.list`: Agent definitions with assigned models
- `agents.defaults.model`: Default model and fallback chain
- `channels.telegram`: Telegram bot configuration
- `tools.agentToAgent`: Inter-agent communication settings

**Important**: Use `${VAR_NAME}` syntax for environment variables (NOT `env:VAR_NAME`).

```json
"apiKey": "${GOOGLE_API_KEY}"  // Correct
"apiKey": "env:GOOGLE_API_KEY"  // Wrong
```

### Agent Personas: `configs/agents/*.yaml`

```yaml
name: main
model: gemini/gemini-3-flash-preview
tools:
  - browser
  - generate_image
  - file_operations
  - code_execution
maxTokens: 16384
```

## Custom Skills

Skills are deployed via `scripts/deploy_custom_skills.sh` into the container at `/app/skills/`.

### Available Skills

| Skill | Purpose | Invocation |
|-------|---------|------------|
| `mcp-client` | Query MCP servers (Keo Thom platform) | `python3 /app/skills/mcp-client/scripts/mcp_call.py --server keothom --tool platform_overview` |
| `r2-upload` | Upload to Cloudflare R2 | `python3 /app/skills/r2-upload/scripts/upload.py /path/to/file` |
| `imgur-upload` | Upload to Imgur (fallback) | `python3 /app/skills/imgur-upload/scripts/upload.py /path/to/file` |
| `camoufox` | Stealth browser automation | Python with `camoufox.sync_api` |

### Skill Structure

```
skills/<name>/
├── SKILL.md        # Documentation (required, with YAML frontmatter)
├── scripts/        # Executable scripts
├── servers.json    # MCP server configs (if applicable)
└── README.md       # Additional docs (optional)
```

## Code Style Guidelines

### Shell Scripts

- **Shebang**: `#!/usr/bin/env bash` or `#!/bin/bash`
- **Strict mode**: Always use `set -euo pipefail`
- **Functions**: Use `snake_case` naming
- **Logging**: Use `log()`, `warn()`, `fatal()` helper functions
- **Quote variables**: Always use `"$VAR"` not `$VAR`
- **Template header**:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd)
```

### JSON Configs

- **Environment variables**: Use `${VAR_NAME}` syntax
- **Indentation**: 2 spaces
- **Comments**: JSON5 comments allowed in OpenClaw configs
- **Never hardcode secrets**: Always reference env vars

### YAML (Agent Personas)

- Use 2-space indentation
- Keep persona files minimal and focused

## GCP Infrastructure

| Resource | Value |
|----------|-------|
| Project | `central-point-477516-v8` |
| Region | `us-central1` |
| Zone | `us-central1-a` |
| VM Name | `openclaw-gateway` |
| Machine Type | `e2-small` / `e2-medium` |
| OS | Debian 12 |

### Required Firewall Rules

| Port | Purpose |
|------|---------|
| 22 | SSH access |
| 80 | HTTP (Caddy/ACME) |
| 443 | HTTPS (Caddy) |
| 18789 | OpenClaw gateway (if not using Caddy) |

**Important**: VM must have `cloud-platform` OAuth scope for GCP API access.

## Deployment Workflow

### Initial Deployment

1. Run `./scripts/deploy-gcp-interactive.sh`
2. Script prompts for all required variables
3. Automated steps:
   - Enable GCP APIs (compute, dns, aiplatform)
   - Reserve static external IP
   - Create firewall rules
   - Create/reuse VM
   - Bootstrap Docker and OpenClaw
   - Optional: Configure Cloud DNS A record
   - Optional: Install Caddy reverse proxy

### Configuration Updates

```bash
# Copy updated config to VM
gcloud compute scp configs/openclaw.json openclaw-gateway:~/.openclaw/openclaw.json --zone=us-central1-a

# Restart service
gcloud compute ssh openclaw-gateway --zone=us-central1-a --command="cd ~/openclaw && docker compose restart openclaw"
```

### After VM Reboot

```bash
# Run on VM to restore container state
./scripts/setup-openclaw.sh
```

## Testing & Validation

There are no automated tests in this repository. Validate manually:

1. **Deployment**: Check VM status in GCP Console
2. **Services**: Run `docker compose ps` on VM
3. **Logs**: Check `docker compose logs openclaw`
4. **Telegram**: Send test message to bot
5. **Gateway**: `curl http://localhost:18789/health` (from VM)

## Troubleshooting

| Issue | Cause | Fix |
|-------|-------|-----|
| `ACCESS_TOKEN_SCOPE_INSUFFICIENT` | VM lacks `cloud-platform` scope | Recreate VM with correct scope |
| Telegram 400 "empty body" | Wrong env var syntax in config | Change `env:VAR` to `${VAR}` |
| `BOT_COMMAND_INVALID` | Invalid custom command format | Check `channels.telegram.customCommands` |
| Model not found | Wrong model ID in config | Verify against provider's model list |
| HTTPS cert not issued | DNS not propagated | Wait for DNS, check ports 80/443 |
| Public URL not reachable | Firewall/DNS mismatch | Verify firewall rules and A record |

## Security Considerations

- **Never commit `.env`**: Contains API keys and tokens
- **Never commit `*.key` or `*.pem`**: Private key files
- **Use Caddy for HTTPS**: Prefer reverse proxy over exposing raw gateway port
- **Bind gateway to localhost** when using Caddy: `OPENCLAW_GATEWAY_HOST_BIND=127.0.0.1`
- **API keys in environment**: Never hardcode credentials in JSON configs
- **VM scope**: Use minimal required OAuth scopes

## Related Documentation

- `SOUL.md` — Agent personality and behavioral guidelines
- `HANDOFF.md` — Current deployment state and pending issues
- `configs/HEARTBEAT.md` — Scheduled cron workflows
- `configs/MEMORY.md` — User preferences and learned patterns
- `examples/openclaw-config/` — Reference configurations from upstream

## LLM Provider Configuration

Configured providers in `configs/openclaw.json`:

| Provider | Default Model | Use Case |
|----------|---------------|----------|
| gemini | `gemini-3-flash-preview` | Primary (fast, multimodal) |
| openrouter | `openai/gpt-5-mini` | Fallback |
| kimi | `kimi-k2-0905-preview` | Code tasks |
| groq | `openai/gpt-oss-120b` | Fast inference (optional) |

Model fallback chain is defined in `agents.defaults.model.fallbacks`.
