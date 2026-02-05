# OpenClaw GCP Complete Setup Guide

> **Prompt:** "Deploy OpenClaw trên GCP theo guide `openclaw_setup_guide.md`"

---

## 📋 Yêu Cầu

- GCP Account với Billing enabled
- Domain (cho Cloudflare Tunnel)
- Cloudflare Account (Zero Trust)

---

## Phase 1: Tạo GCP VM

### 1.1 Tạo Project & Enable APIs

```bash
# Tạo project mới
gcloud projects create <PROJECT_ID> --name="OpenClaw Gateway"
gcloud config set project <PROJECT_ID>

# Link billing
gcloud billing projects link <PROJECT_ID> --billing-account=<BILLING_ID>

# Enable APIs
gcloud services enable compute.googleapis.com aiplatform.googleapis.com
```

### 1.2 Tạo VM

```bash
gcloud compute instances create openclaw-gateway \
    --zone=<ZONE> \
    --machine-type=e2-medium \
    --boot-disk-size=30GB \
    --image-family=debian-12 \
    --image-project=debian-cloud \
    --scopes=cloud-platform
```

**Cấu hình khuyến nghị:**
| Spec | Value |
|------|-------|
| Machine | `e2-medium` (2 vCPU, 4GB RAM) |
| Disk | 30GB SSD |
| OS | Debian 12 |
| Scopes | `cloud-platform` ⚠️ Quan trọng! |

### 1.3 SSH vào VM

```bash
gcloud compute ssh openclaw-gateway --zone=<ZONE>
```

---

## Phase 2: Setup Docker

```bash
# Install Docker
sudo apt-get update
sudo apt-get install -y git curl ca-certificates
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER

# Re-login để apply group
exit
gcloud compute ssh openclaw-gateway --zone=<ZONE>

# Verify
docker --version
```

---

## Phase 3: Deploy OpenClaw

### 3.1 Clone Repository

```bash
git clone https://github.com/openclaw/openclaw.git ~/openclaw
cd ~/openclaw
mkdir -p ~/.openclaw ~/.openclaw/workspace
```

### 3.2 Run Setup

```bash
chmod +x docker-setup.sh
./docker-setup.sh --non-interactive
```

### 3.3 Verify

```bash
docker compose ps
curl -s http://localhost:18789 | head -5
```

---

## Phase 4: CLIProxyAPI (Backend LLM)

```bash
git clone https://github.com/router-for-me/CLIProxyAPI.git ~/CLIProxyAPI
cd ~/CLIProxyAPI
mkdir -p auths logs

# Configure
nano config.yaml

# Start
sudo docker compose up -d
```

---

## Phase 5: Cloudflare Tunnel (Chi tiết)

### 5.1 Tạo Tunnel trên Dashboard

1. Vào [Cloudflare Zero Trust](https://one.dash.cloudflare.com/)
2. **Networks** → **Tunnels** → **Create a tunnel**
3. Đặt tên tunnel (VD: `openclaw-gateway`)
4. Copy **Tunnel Token** (dạng `eyJhIjoiNj...`)

### 5.2 Chạy Cloudflared Container

```bash
sudo docker run -d \
    --name cloudflared \
    --restart unless-stopped \
    --network openclaw_default \
    cloudflare/cloudflared:latest \
    tunnel --no-autoupdate run --token <TUNNEL_TOKEN>
```

> **Note:** Thêm `--network openclaw_default` nếu muốn connect trực tiếp tới container.

### 5.3 Configure Public Hostname

Trong Cloudflare Dashboard → Tunnel → **Public Hostname**:

| Field | Value |
|-------|-------|
| Subdomain | `openclaw` (hoặc tên khác) |
| Domain | `<your-domain>` |
| Type | HTTP |
| URL | `openclaw-gateway:18789` hoặc `localhost:18789` |

**Nếu cùng Docker network:** dùng tên container `openclaw-gateway:18789`
**Nếu standalone:** dùng `localhost:18789` hoặc `host.docker.internal:18789`

### 5.4 Cấu hình trustedProxies

**QUAN TRỌNG**: OpenClaw cần trust IP của Cloudflare proxy.

**File:** `~/.openclaw/openclaw.json`

```json
{
  "gateway": {
    "mode": "local",
    "trustedProxies": [
      "172.18.0.1",
      "172.16.0.0/12",
      "10.0.0.0/8",
      "192.168.0.0/16",
      "127.0.0.1"
    ]
  }
}
```

---

## Phase 6: Cloudflare Access (Google SSO) - Optional

### 6.1 Tạo Google OAuth Credentials

1. Vào [Google Cloud Console > Credentials](https://console.cloud.google.com/apis/credentials)
2. **Create Credentials** → **OAuth client ID**
3. Application type: **Web application**
4. Authorized redirect URIs:
   ```
   https://<TEAM_NAME>.cloudflareaccess.com/cdn-cgi/access/callback
   ```
5. Copy **Client ID** và **Client Secret**

### 6.2 Add Google Login trong Cloudflare

1. Cloudflare Zero Trust → **Settings** → **Authentication**
2. **Login methods** → **Add new** → **Google**
3. Paste Client ID và Client Secret
4. Save

### 6.3 Tạo Access Application

1. **Access** → **Applications** → **Add an application**
2. Chọn **Self-hosted**
3. Config:
   - Application name: `OpenClaw`
   - Session duration: `24 hours`
   - Application domain: `openclaw.<your-domain>`

4. Add Policy:
   - Policy name: `Allow Users`
   - Action: `Allow`
   - Include → Emails → `<your-email>` (hoặc domain)

5. Save

### 6.4 Verify

1. Mở Incognito browser
2. Vào `https://openclaw.<your-domain>`
3. Cloudflare sẽ redirect đến trang login Google
4. Sau khi auth → thấy OpenClaw UI

---

## Phase 7: Cấu Hình OpenClaw

### 7.1 Gateway Config

**File:** `~/.openclaw/openclaw.json`

```json
{
  "gateway": {
    "mode": "local",
    "trustedProxies": ["172.18.0.1", "10.0.0.0/8", "127.0.0.1"]
  },
  "models": {
    "providers": {
      "proxypal": {
        "baseUrl": "http://host.docker.internal:8317/v1",
        "apiKey": "<PROXY_KEY>",
        "api": "openai-completions",
        "models": [
          {"id": "claude-sonnet-4-5", "name": "Claude Sonnet 4.5"},
          {"id": "gemini-3-pro-preview", "name": "Gemini 3 Pro"}
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "proxypal/claude-sonnet-4-5",
        "fallbacks": ["proxypal/gemini-3-pro-preview"]
      }
    }
  }
}
```

### 7.2 Environment Variables

**File:** `~/openclaw/.env`

```bash
# Gateway
OPENCLAW_GATEWAY_TOKEN=<auto-generated>

# GCP
GOOGLE_CLOUD_PROJECT=<PROJECT_ID>
GOOGLE_CLOUD_LOCATION=us-central1

# LLM Backend
ANTHROPIC_API_KEY=<PROXY_KEY>
ANTHROPIC_BASE_URL=http://host.docker.internal:8317/v1
```

---

## Phase 8: Vertex AI & Python Packages

### 8.1 Grant IAM Roles

```bash
PROJECT_ID=$(gcloud config get-value project)
SA=$(gcloud compute instances describe openclaw-gateway --zone=<ZONE> \
  --format="get(serviceAccounts[0].email)")

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:$SA" \
  --role="roles/aiplatform.user"
```

### 8.2 Install Packages

```bash
sudo docker exec openclaw-openclaw-gateway-1 bash -c "
  apt-get update && apt-get install -y python3-pip chromium
  pip3 install google-cloud-aiplatform cognee playwright --break-system-packages
  /home/node/.local/bin/playwright install chromium
"
```

### 8.3 Test

```bash
# Vertex AI
sudo docker exec openclaw-openclaw-gateway-1 python3 -c "
import vertexai
vertexai.init(location='us-central1')
print('✅ Vertex AI ready!')
"

# Playwright
sudo docker exec openclaw-openclaw-gateway-1 python3 -c "
from playwright.sync_api import sync_playwright
with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    print('✅ Playwright ready!')
    browser.close()
"
```

---

## Phase 9: Multi-Agent Setup (Multiple Telegram Bots)

> **⚠️ CRITICAL**: Đọc kỹ phần này trước khi cấu hình multi-agent!

### 9.1 Tạo Telegram Bots

1. Chat với [@BotFather](https://t.me/BotFather) trên Telegram
2. Tạo bot mới cho mỗi agent:
   ```
   /newbot
   Name: Javis
   Username: your_javis_bot
   
   /newbot
   Name: Lena
   Username: your_lena_bot
   ```
3. Lưu lại bot tokens

### 9.2 Cấu hình Multi-Agent

**File:** `~/.openclaw/openclaw.json`

```json
{
  "gateway": {
    "mode": "local"
  },
  "models": {
    "providers": {
      "proxypal": {
        "baseUrl": "http://host.docker.internal:8317/v1",
        "apiKey": "<PROXY_KEY>",
        "api": "openai-completions",
        "models": [
          {"id": "claude-opus-4-5-thinking", "name": "Claude Opus 4.5"},
          {"id": "claude-sonnet-4-5", "name": "Claude Sonnet 4.5"},
          {"id": "gemini-3-pro-high", "name": "Gemini 3 Pro High"}
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "proxypal/claude-sonnet-4-5",
        "fallbacks": []
      },
      "maxConcurrent": 4
    },
    "list": [
      {
        "id": "main",
        "name": "Javis",
        "default": true,
        "model": "proxypal/claude-opus-4-5-thinking"
      },
      {
        "id": "lena",
        "name": "Lena",
        "model": "proxypal/gemini-3-pro-high"
      },
      {
        "id": "marcus",
        "name": "Marcus",
        "model": "proxypal/gemini-3-pro-high"
      }
    ]
  },
  "bindings": [
    {"agentId": "main", "match": {"channel": "telegram", "accountId": "javis"}},
    {"agentId": "lena", "match": {"channel": "telegram", "accountId": "lena"}},
    {"agentId": "marcus", "match": {"channel": "telegram", "accountId": "marcus"}}
  ],
  "tools": {
    "agentToAgent": {
      "enabled": true,
      "allow": ["main", "lena", "marcus"]
    }
  },
  "channels": {
    "telegram": {
      "enabled": true,
      "accounts": {
        "javis": {"botToken": "<JAVIS_BOT_TOKEN>"},
        "lena": {"botToken": "<LENA_BOT_TOKEN>"},
        "marcus": {"botToken": "<MARCUS_BOT_TOKEN>"}
      },
      "groupPolicy": "open",
      "streamMode": "partial"
    }
  }
}
```

### 9.3 Tạo Agent Directories (Optional)

```bash
# Tạo workspace + agent config cho mỗi agent
for AGENT in main lena marcus; do
  sudo docker exec openclaw-openclaw-gateway-1 mkdir -p /home/node/.openclaw/agents/$AGENT
  sudo docker exec openclaw-openclaw-gateway-1 mkdir -p /home/node/.openclaw/workspace-$AGENT
done
```

### 9.4 Agent YAML Config (Optional)

Mỗi agent có thể có riêng `agent.yaml`:

```bash
sudo docker exec openclaw-openclaw-gateway-1 bash -c "cat > /home/node/.openclaw/agents/lena/agent.yaml << 'EOF'
name: lena
model: proxypal/gemini-3-pro-high
systemPrompt: |
  You are Lena, image creation specialist.
  Respond in Vietnamese. Be creative!
tools:
  - code_execution
  - send_image
EOF"
```

### 9.5 Pairing Telegram Users

```bash
# List pending users
sudo docker compose exec openclaw-gateway openclaw pairing list telegram --pending

# Approve user
sudo docker compose exec openclaw-gateway openclaw pairing approve telegram <USER_ID>
```

### ⚠️ Common Mistakes to AVOID

| ❌ Sai | ✅ Đúng | Lý do |
|--------|---------|-------|
| `anthropic/claude-opus-4-5` | `proxypal/claude-opus-4-5-thinking` | Phải dùng prefix `proxypal/` khi qua LiteLLM proxy |
| `tools.agentToAgent.allowAny: true` | Chỉ dùng `enabled` + `allow` | `allowAny` không phải valid config key |
| Thiếu `models.providers` section | Luôn định nghĩa provider với `baseUrl`, `apiKey`, `models` | OpenClaw cần biết cách gọi model |
| Dùng `auth-profiles.json` | Đặt `apiKey` trong `models.providers.<name>` | Auth được config trong openclaw.json |
| Không restart sau khi đổi config | `docker compose restart openclaw-gateway` | Config chỉ load lúc startup |

### 9.6 Verify Multi-Agent

```bash
# Check logs
sudo docker logs openclaw-openclaw-gateway-1 --since 1m 2>&1 | grep -E "telegram|agent"

# Expected output:
# [telegram] [javis] starting provider (@your_javis_bot)
# [telegram] [lena] starting provider (@your_lena_bot)
# [telegram] [marcus] starting provider (@your_marcus_bot)
```

---

## Phase 10: Access & Verification

### Get Token

```bash
cat ~/openclaw/.env | grep TOKEN
```

### Access UI

- URL: `https://openclaw.<your-domain>/`
- Paste token vào Settings
- Hoặc: `https://openclaw.<your-domain>/?token=<TOKEN>`

---

## 📁 Directory Structure

```
~/openclaw/
├── docker-compose.yml
├── .env
└── Dockerfile

~/.openclaw/
├── openclaw.json
├── agents/
│   ├── main/agent.yaml
│   └── lena-image-processor/agent.yaml
├── devices/
│   ├── paired.json
│   └── pending.json
└── workspace/
```

---

## ⚠️ Troubleshooting

| Issue | Solution |
|-------|----------|
| `ACCESS_TOKEN_SCOPE_INSUFFICIENT` | VM cần scope `cloud-platform` |
| `token_mismatch` | Reset devices + clear browser |
| `Proxy headers from untrusted` | Thêm IP vào `trustedProxies` |
| `Unknown model: anthropic/...` | Dùng `proxypal/<model>` khi qua LiteLLM proxy |
| `No API key found for provider` | Thêm `models.providers.<name>.apiKey` trong openclaw.json |
| `Unrecognized key: allowAny` | Remove `allowAny`, chỉ dùng `enabled` + `allow` |
| 403 Forbidden (Cloudflare) | Check Access policy emails |
| Redirect loop | Check trustedProxies config |
| `Telegram configured, not enabled` | Thêm `"enabled": true` trong `channels.telegram` |
| Bot không phản hồi | Check `docker compose ps`, verify container UP |

### Nuclear Reset

```bash
sudo docker exec openclaw-openclaw-gateway-1 bash -c "
  echo {} > /home/node/.openclaw/devices/paired.json
  echo {} > /home/node/.openclaw/devices/pending.json
"
sudo docker compose restart openclaw-gateway
# Clear browser localStorage
```

---

## 🔧 Quick Commands

```bash
# SSH
gcloud compute ssh openclaw-gateway --zone=<ZONE>

# Logs
sudo docker logs openclaw-openclaw-gateway-1 --since 5m

# Restart
cd ~/openclaw && sudo docker compose restart openclaw-gateway

# Full rebuild
sudo docker compose down && sudo docker compose up -d

# Check tunnel
sudo docker logs cloudflared --since 5m
```
