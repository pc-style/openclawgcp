# OpenClaw GCP Deployment Handoff

## Project Overview

**OpenClaw** is an automated AI assistant gateway deployed on Google Cloud Platform. It runs a suite of 12 predefined workflows to handle tasks like daily briefings, email triage, meeting preparation and recording, calendar management, and research.

### Key Goals

- **Automate Routine Tasks:** Daily summaries, email filtering, meeting prep.
- **Centralized Intelligence:** Uses Gemini 2.0 Flash (and Perplexity/Replicate) to process information.
- **Reliable Execution:** Runs 24/7 on a cloud VM with Redis for state persistence.

## Infrastructure Details

### Google Cloud Platform (GCP)

- **Project ID:** `central-point-477516-v8`
- **Region/Zone:** `us-central1-a`
- **VM Instance:** `openclaw-gateway` (e2-small, 2 vCPU, 2GB RAM + 4GB Swap)
- **External IP:** `34.30.12.186`
- **Internal IP:** `10.128.0.7`
- **Firewall:** `allow-openclaw` (Ports: 80, 443, 18789)

### Service Architecture (Docker Compose)

Running on VM at `~/openclaw/docker-compose.yml`:

1. **`openclaw-gateway`** (Node.js/Python App)
    - **Image:** `openclaw:chromium` (Custom built capable of browser automation)
    - **Port:** `18789` (Mapped to host)
    - **Volumes:**
        - `~/.openclaw` -> `/root/.openclaw` (Config & State)
        - `~/openclaw/workspace` -> `/root/.openclaw/workspace` (Data storage)

2. **`redis`** (Cache & Queue)
    - **Image:** `redis:7-alpine`
    - **Persistence:** `redis-data` volume

3. **`playwright`** (Browser Automation)
    - **Image:** `mcr.microsoft.com/playwright:v1.40.0-focal`
    - **Purpose:** Headless browser for scraping and web tasks.

## Configuration & Files

**Local Project Directory:** `~/projects/gcp-oc/`
(All files here are mirrored to the VM)

| File | VM Location | Purpose |
| :--- | :--- | :--- |
| `.env` | `~/openclaw/.env` | API Keys & Secrets (Gemini, Telegram, etc.) |
| `docker-compose.yml` | `~/openclaw/docker-compose.yml` | Service definitions |
| `configs/config.json` | `~/.openclaw/config.json` | System config (Models, Providers, Cron) |
| `configs/HEARTBEAT.md`| `~/.openclaw/HEARTBEAT.md` | **Core Logic:** Definitions of all 12 workflows |
| `configs/MEMORY.md` | `~/.openclaw/MEMORY.md` | User profile & learned patterns |

## Workflows (Defined in HEARTBEAT.md)

1. **Daily Brief:** 7:00 AM summary of calendar, email, and news.
2. **Product Hunt Brief:** 2:55 PM digest of top AI/Dev tools.
3. **Email Triage:** Real-time importance scoring and labeling.
4. **Meeting Prep:** 15-min pre-meeting research and context.
5. **Meeting Recording:** Join, record, transcribe, and summarize calls.
6. **Email Drafting:** AI-assisted replies based on tone preferences.
7. **Calendar Management:** Find slots and schedule meetings.
8. **Linear Integration:** Create issues from tasks/meetings.
9. **Proactive Reminders:** Smart reminders that respect alert limits.
10. **Web Scraping:** Extract data from URLs for context.
11. **Telegram Commands:** `/brief`, `/start`, `/research`, etc.

## Current Status & Next Steps

### ✅ Completed

- VM Provisioned & Configured (Docker, Swap, Git).
- Services Deployed & Running (`docker-compose up -d`).
- Configuration Files Created & Uploaded.
- Secrets Partially Populated (Gemini, OpenRouter, Kimi, Telegram).

### ⚠️ Pending Actions

1. **Secret Population:** The `.env` file on the VM (`~/openclaw/.env`) is missing keys for:
    - `PERPLEXITY_API_KEY` (Search) DONE
    - `LINEAR_API_KEY` (Task Management) LATER
    <!-- - `REPLICATE_API_TOKEN` (Image Gen - Optional) -->
    <!-- - `GMAIL_REFRESH_TOKEN` (If GOG CLI is not used) -->

### Commands Reference

**Access VM:**

```bash
gcloud compute ssh openclaw-gateway --zone=us-central1-a
```

**Manage Services:**

```bash
cd ~/openclaw
docker compose restart
docker compose logs -f openclaw
```

**Edit Configs:**

```bash
nano ~/.openclaw/config.json
nano ~/.openclaw/HEARTBEAT.md
```

**Local Dashboard (SSH Tunnel):**

```bash
gcloud compute ssh openclaw-gateway --zone=us-central1-a -- -N -L 18789:127.0.0.1:18789
# Then open http://127.0.0.1:18789
```
