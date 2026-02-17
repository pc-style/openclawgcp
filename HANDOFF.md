# HANDOFF — OpenClaw Telegram 400 "empty body" Investigation

## Primary Goal for Next Session
Fix Telegram chat replies failing with HTTP 400 `"empty body"` when users message the bot. **Do NOT use Groq provider.** Fix all configuration errors.

---

## ALL ISSUES IDENTIFIED

### Issue 1: Wrong Environment Variable Syntax (CRITICAL)
**Files affected:** `configs/openclaw.json`, `~/.openclaw/openclaw.json` (VM)

**Problem:** Config uses `env:VAR_NAME` but OpenClaw expects `${VAR_NAME}` syntax.

**Current (WRONG):**
```json
"gemini": {
  "apiKey": "env:GOOGLE_API_KEY"
}
```

**Expected (CORRECT):**
```json
"gemini": {
  "apiKey": "${GOOGLE_API_KEY}"
}
```

**Affected providers in `configs/openclaw.json`:**
- Line 23: `"apiKey": "env:OPENROUTER_API_KEY"` → `"${OPENROUTER_API_KEY}"`
- Line 62: `"apiKey": "env:GOOGLE_API_KEY"` → `"${GOOGLE_API_KEY}"`
- Line 120: `"apiKey": "env:KIMI_API_KEY"` → `"${KIMI_API_KEY}"`
- Line 159: `"apiKey": "env:GROQ_API_KEY"` → `"${GROQ_API_KEY}"` (or remove groq entirely)

**Affected in `configs/config.json`:**
- Line 17: `"token": "env:TELEGRAM_BOT_TOKEN"` → `"${TELEGRAM_BOT_TOKEN}"`
- Line 18: `"chatId": "env:TELEGRAM_CHAT_ID"` → `"${TELEGRAM_CHAT_ID}"`

---

### Issue 2: GROQ Provider Not Used (User Request)
**Problem:** User explicitly requested NOT to use Groq. Remove all Groq references.

**Actions needed:**
1. Remove `"groq"` provider from `models.providers` in `configs/openclaw.json`
2. Remove `"marcus"` agent (uses groq) from `agents.list` in `configs/openclaw.json`
3. Remove `"groq/openai/gpt-oss-120b"` from `agents.defaults.model.fallbacks`
4. Remove `"marcus"` from `tools.agentToAgent.allow` list

---

### Issue 3: Missing GROQ_API_KEY in VM .env
**Problem:** Even if Groq was used, the API key is missing from VM `.env`.

**Current state:** No `GROQ_API_KEY` found in `~/openclaw/.env`

---

### Issue 4: BOT_COMMAND_INVALID Error
**Problem:** Telegram command registration fails on startup.

**Log evidence:**
```
2026-02-17T10:41:38.473Z [telegram] setMyCommands failed: Call to 'setMyCommands' failed! (400: Bad Request: BOT_COMMAND_INVALID)
```

**Possible causes:**
- Invalid command format (e.g., `skill-creator` sanitized to `/skill_creator` may be invalid)
- Custom commands in config may have issues

**Fix:** Check `channels.telegram.customCommands` setting - currently set to `[]` in local config.

---

### Issue 5: Stream Mode Configuration
**Problem:** Stream mode `"partial"` may cause issues with draft message handling.

**Location:** `configs/openclaw.json` line 288
```json
"streamMode": "partial"
```

**Note:** This may be fine but could be tested with `"final"` or disabled.

---

### Issue 6: Telegram DM Policy Mismatch
**Problem:** Local config has `"dmPolicy": "pairing"` but VM config has `"dmPolicy": "open"`.

**Local (`configs/openclaw.json`):** `"dmPolicy": "pairing"`  
**VM (`~/.openclaw/openclaw.json`):** `"dmPolicy": "open"`

---

## Files to Fix

1. `/Users/pcstyle/projects/gcp-oc/configs/openclaw.json` — Fix env var syntax, remove Groq
2. `/Users/pcstyle/projects/gcp-oc/configs/config.json` — Fix env var syntax
3. `~/.openclaw/openclaw.json` (VM) — Sync fixes after local changes

---

## Commands to Deploy Fixes

```bash
# 1. Copy fixed configs to VM
gcloud compute scp configs/openclaw.json openclaw-gateway:~/.openclaw/openclaw.json --zone=us-central1-a

# 2. Restart OpenClaw container
gcloud compute ssh openclaw-gateway --zone=us-central1-a --command="cd ~/openclaw && docker compose restart openclaw"

# 3. Verify logs
gcloud compute ssh openclaw-gateway --zone=us-central1-a --command="docker logs openclaw-gateway --tail 50"
```

---

## Runtime Facts
- Workspace: `/Users/pcstyle/projects/gcp-oc`
- VM: `openclaw-gateway` in `us-central1-a`
- VM config path: `~/.openclaw/openclaw.json`
- Bot username: `@lexi_pcstyle_bot`
- Test chat: `8153548124`

---

## Context7 Documentation Reference
OpenClaw uses `${VAR_NAME}` syntax for environment variable substitution (not `env:VAR_NAME`).
