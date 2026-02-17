#!/usr/bin/env bash
# Interactive end-to-end deployment for OpenClaw on GCP.
# This script provisions infrastructure, deploys Docker services, and optionally
# configures a public URL with an A record and Caddy reverse proxy.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd)

DEFAULT_REPO_URL=$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)
DEFAULT_REPO_REF=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
if [[ -z "${DEFAULT_REPO_REF:-}" || "$DEFAULT_REPO_REF" == "HEAD" ]]; then
  DEFAULT_REPO_REF=$(git -C "$REPO_ROOT" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)
fi
if [[ -z "${DEFAULT_REPO_REF:-}" ]]; then
  DEFAULT_REPO_REF="main"
fi

log() {
  printf '[INFO] %s\n' "$1"
}

warn() {
  printf '[WARN] %s\n' "$1" >&2
}

fatal() {
  printf '[ERROR] %s\n' "$1" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fatal "Missing required command: $1"
}

generate_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
  else
    # Fallback if openssl is unavailable.
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48
  fi
}

prompt_value() {
  local __var="$1"
  local __label="$2"
  local __default="${3:-}"
  local __secret="${4:-false}"
  local __required="${5:-false}"
  local __input=""

  while true; do
    if [[ "$__secret" == "true" ]]; then
      if [[ -n "$__default" ]]; then
        read -r -s -p "$__label [press Enter to keep generated value]: " __input
      else
        read -r -s -p "$__label: " __input
      fi
      printf '\n'
      [[ -z "$__input" ]] && __input="$__default"
    else
      if [[ -n "$__default" ]]; then
        read -r -p "$__label [$__default]: " __input
        [[ -z "$__input" ]] && __input="$__default"
      else
        read -r -p "$__label: " __input
      fi
    fi

    if [[ "$__required" == "true" && -z "$__input" ]]; then
      warn "This value is required."
      continue
    fi

    printf -v "$__var" '%s' "$__input"
    return
  done
}

prompt_yes_no() {
  local __var="$1"
  local __label="$2"
  local __default="${3:-yes}"
  local __input=""
  local __hint="[Y/n]"

  if [[ "$__default" == "no" ]]; then
    __hint="[y/N]"
  fi

  while true; do
    read -r -p "$__label $__hint: " __input
    __input=$(printf '%s' "$__input" | tr '[:upper:]' '[:lower:]')
    if [[ -z "$__input" ]]; then
      __input="$__default"
    fi
    case "$__input" in
      y|yes)
        printf -v "$__var" 'true'
        return
        ;;
      n|no)
        printf -v "$__var" 'false'
        return
        ;;
      *)
        warn "Please answer yes or no."
        ;;
    esac
  done
}

normalize_fqdn() {
  local raw="$1"
  raw="${raw#http://}"
  raw="${raw#https://}"
  raw="${raw%%/*}"
  raw="${raw%.}"
  printf '%s' "$raw"
}

shell_quote() {
  printf '%q' "$1"
}

write_env_line() {
  local key="$1"
  local value="$2"
  value="${value//$'\n'/\\n}"
  value="${value//\'/\'\"\'\"\'}"
  printf "%s='%s'\n" "$key" "$value"
}

wait_for_ssh() {
  local vm_name="$1"
  local zone="$2"
  local attempt=1
  local max_attempts=25

  until gcloud compute ssh "$vm_name" --zone "$zone" --command "echo ready" --quiet >/dev/null 2>&1; do
    if (( attempt >= max_attempts )); then
      fatal "Unable to connect to VM via SSH after $max_attempts attempts."
    fi
    log "Waiting for SSH to become available (attempt $attempt/$max_attempts)..."
    attempt=$((attempt + 1))
    sleep 10
  done
}

main() {
  require_cmd gcloud
  require_cmd git
  require_cmd mktemp

  local active_account
  active_account=$(gcloud auth list --filter=status:ACTIVE --format='value(account)' | head -n1 || true)
  [[ -z "$active_account" ]] && fatal "No active gcloud account found. Run: gcloud auth login"
  log "Using gcloud account: $active_account"

  local local_user
  local_user=$(id -un)

  printf '\n=== OpenClaw GCP Interactive Deployment ===\n\n'

  local PROJECT_ID
  local CREATE_PROJECT_IF_MISSING
  local BILLING_ACCOUNT_ID
  local REGION
  local ZONE
  local VM_NAME
  local MACHINE_TYPE
  local BOOT_DISK_SIZE
  local STATIC_IP_NAME
  local FIREWALL_RULE_NAME
  local INSTANCE_TAG
  local REMOTE_APP_DIR
  local DEPLOY_REPO_URL
  local DEPLOY_REPO_REF

  local OPENCLAW_GATEWAY_TOKEN
  local OPENCLAW_IMAGE
  local OPENCLAW_CONFIG_DIR
  local OPENCLAW_WORKSPACE_DIR
  local OPENCLAW_GATEWAY_PORT
  local OPENCLAW_BRIDGE_PORT
  local OPENCLAW_GATEWAY_HOST_BIND
  local OPENCLAW_BRIDGE_HOST_BIND
  local OPENCLAW_GATEWAY_BIND
  local OPENCLAW_AGENT_MODEL
  local OPENROUTER_API_KEY
  local OPENROUTER_BASE_URL
  local GEMINI_API_KEY
  local GEMINI_BASE_URL
  local KIMI_API_KEY
  local KIMI_BASE_URL
  local GROQ_API_KEY
  local GROQ_BASE_URL
  local R2_ACCESS_KEY_ID
  local R2_SECRET_ACCESS_KEY
  local KEOTHOM_MCP_API_KEY
  local CLAUDE_AI_SESSION_KEY
  local CLAUDE_WEB_SESSION_KEY
  local CLAUDE_WEB_COOKIE

  local ENABLE_PUBLIC_URL
  local PUBLIC_URL_FQDN
  local ENABLE_CADDY
  local CADDY_EMAIL
  local MANAGE_DNS_RECORD
  local DNS_ZONE_NAME
  local CREATE_DNS_ZONE_IF_MISSING
  local DNS_ZONE_DNS_NAME
  local DNS_ZONE_DESCRIPTION
  local DNS_TTL

  local generated_token
  generated_token=$(generate_token)

  prompt_value PROJECT_ID "GCP project ID" "" false true
  prompt_yes_no CREATE_PROJECT_IF_MISSING "Create the project if it does not exist?" yes
  prompt_value BILLING_ACCOUNT_ID "Billing account ID (optional, format XXXX-XXXXXX-XXXXXX)" "" false false
  prompt_value REGION "GCP region" "us-central1" false true
  prompt_value ZONE "GCP zone" "us-central1-a" false true
  prompt_value VM_NAME "VM name" "openclaw-gateway" false true
  prompt_value MACHINE_TYPE "Machine type" "e2-medium" false true
  prompt_value BOOT_DISK_SIZE "Boot disk size (e.g. 30GB)" "30GB" false true
  prompt_value STATIC_IP_NAME "Static external IP resource name" "${VM_NAME}-ip" false true
  prompt_value FIREWALL_RULE_NAME "Firewall rule name" "${VM_NAME}-allow-web" false true
  prompt_value INSTANCE_TAG "Network tag for VM/firewall targeting" "openclaw-gateway" false true
  prompt_value REMOTE_APP_DIR "Remote app directory on VM" "/home/${local_user}/openclawgcp" false true
  prompt_value DEPLOY_REPO_URL "Deployment repo URL on VM" "${DEFAULT_REPO_URL:-https://github.com/pc-style/openclawgcp.git}" false true
  prompt_value DEPLOY_REPO_REF "Deployment repo branch/tag" "${DEFAULT_REPO_REF:-main}" false true

  prompt_value OPENCLAW_GATEWAY_TOKEN "OPENCLAW_GATEWAY_TOKEN" "$generated_token" true true
  prompt_value OPENCLAW_IMAGE "OPENCLAW_IMAGE" "openclaw:chromium" false true
  prompt_value OPENCLAW_CONFIG_DIR "OPENCLAW_CONFIG_DIR" "/home/${local_user}/.openclaw" false true
  prompt_value OPENCLAW_WORKSPACE_DIR "OPENCLAW_WORKSPACE_DIR" "/home/${local_user}/.openclaw/workspace" false true
  prompt_value OPENCLAW_GATEWAY_PORT "OPENCLAW_GATEWAY_PORT" "18789" false true
  prompt_value OPENCLAW_BRIDGE_PORT "OPENCLAW_BRIDGE_PORT" "18790" false true
  prompt_value OPENCLAW_GATEWAY_HOST_BIND "OPENCLAW_GATEWAY_HOST_BIND" "127.0.0.1" false true
  prompt_value OPENCLAW_BRIDGE_HOST_BIND "OPENCLAW_BRIDGE_HOST_BIND" "127.0.0.1" false true
  prompt_value OPENCLAW_GATEWAY_BIND "OPENCLAW_GATEWAY_BIND" "lan" false true
  prompt_value OPENCLAW_AGENT_MODEL "OPENCLAW_AGENT_MODEL" "gemini/gemini-3-flash-preview" false true
  prompt_value OPENROUTER_API_KEY "OPENROUTER_API_KEY" "" true true
  prompt_value OPENROUTER_BASE_URL "OPENROUTER_BASE_URL" "https://openrouter.ai/api/v1" false true
  prompt_value GEMINI_API_KEY "GEMINI_API_KEY" "" true true
  prompt_value GEMINI_BASE_URL "GEMINI_BASE_URL" "https://generativelanguage.googleapis.com/v1beta/openai" false true
  prompt_value KIMI_API_KEY "KIMI_API_KEY" "" true true
  prompt_value KIMI_BASE_URL "KIMI_BASE_URL" "https://api.moonshot.cn/v1" false true
  prompt_value GROQ_API_KEY "GROQ_API_KEY" "" true true
  prompt_value GROQ_BASE_URL "GROQ_BASE_URL" "https://api.groq.com/openai/v1" false true
  prompt_value R2_ACCESS_KEY_ID "R2_ACCESS_KEY_ID (optional)" "" false false
  prompt_value R2_SECRET_ACCESS_KEY "R2_SECRET_ACCESS_KEY (optional)" "" true false
  prompt_value KEOTHOM_MCP_API_KEY "KEOTHOM_MCP_API_KEY (optional)" "" true false
  prompt_value CLAUDE_AI_SESSION_KEY "CLAUDE_AI_SESSION_KEY (optional)" "" true false
  prompt_value CLAUDE_WEB_SESSION_KEY "CLAUDE_WEB_SESSION_KEY (optional)" "" true false
  prompt_value CLAUDE_WEB_COOKIE "CLAUDE_WEB_COOKIE (optional)" "" true false

  prompt_yes_no ENABLE_PUBLIC_URL "Configure a public URL (A record + reverse proxy)?" yes
  PUBLIC_URL_FQDN=""
  ENABLE_CADDY="false"
  CADDY_EMAIL=""
  MANAGE_DNS_RECORD="false"
  DNS_ZONE_NAME=""
  CREATE_DNS_ZONE_IF_MISSING="false"
  DNS_ZONE_DNS_NAME=""
  DNS_ZONE_DESCRIPTION="OpenClaw managed DNS zone"
  DNS_TTL="300"

  if [[ "$ENABLE_PUBLIC_URL" == "true" ]]; then
    prompt_value PUBLIC_URL_FQDN "Public FQDN (example: openclaw.example.com)" "" false true
    PUBLIC_URL_FQDN=$(normalize_fqdn "$PUBLIC_URL_FQDN")
    [[ -z "$PUBLIC_URL_FQDN" ]] && fatal "Public FQDN cannot be empty."

    prompt_yes_no ENABLE_CADDY "Install and configure Caddy reverse proxy with automatic HTTPS?" yes
    if [[ "$ENABLE_CADDY" == "true" ]]; then
      prompt_value CADDY_EMAIL "ACME contact email for Caddy (optional)" "" false false
    fi

    prompt_yes_no MANAGE_DNS_RECORD "Manage the DNS A record in Google Cloud DNS?" no
    if [[ "$MANAGE_DNS_RECORD" == "true" ]]; then
      prompt_value DNS_ZONE_NAME "Cloud DNS managed zone name" "" false true
      prompt_yes_no CREATE_DNS_ZONE_IF_MISSING "Create the managed zone if it does not exist?" no
      if [[ "$CREATE_DNS_ZONE_IF_MISSING" == "true" ]]; then
        prompt_value DNS_ZONE_DNS_NAME "Zone DNS name (example: example.com)" "" false true
        DNS_ZONE_DNS_NAME=$(normalize_fqdn "$DNS_ZONE_DNS_NAME")
        prompt_value DNS_ZONE_DESCRIPTION "Managed zone description" "$DNS_ZONE_DESCRIPTION" false true
      fi
      prompt_value DNS_TTL "DNS TTL (seconds)" "$DNS_TTL" false true
    fi
  fi

  printf '\n=== Deployment Summary ===\n'
  printf 'Project:                %s\n' "$PROJECT_ID"
  printf 'Region/Zone:            %s / %s\n' "$REGION" "$ZONE"
  printf 'VM:                     %s (%s, disk %s)\n' "$VM_NAME" "$MACHINE_TYPE" "$BOOT_DISK_SIZE"
  printf 'Static IP resource:     %s\n' "$STATIC_IP_NAME"
  printf 'Firewall rule:          %s\n' "$FIREWALL_RULE_NAME"
  printf 'Repo:                   %s @ %s\n' "$DEPLOY_REPO_URL" "$DEPLOY_REPO_REF"
  printf 'Remote app directory:   %s\n' "$REMOTE_APP_DIR"
  printf 'Gateway port binding:   %s:%s\n' "$OPENCLAW_GATEWAY_HOST_BIND" "$OPENCLAW_GATEWAY_PORT"
  if [[ "$ENABLE_PUBLIC_URL" == "true" ]]; then
    printf 'Public URL FQDN:        %s\n' "$PUBLIC_URL_FQDN"
    printf 'Caddy enabled:          %s\n' "$ENABLE_CADDY"
    printf 'Cloud DNS management:   %s\n' "$MANAGE_DNS_RECORD"
  fi
  printf '\n'

  local PROCEED
  prompt_yes_no PROCEED "Proceed with deployment?" no
  [[ "$PROCEED" == "false" ]] && fatal "Deployment aborted by user."

  log "Setting gcloud project context..."
  if ! gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)' >/dev/null 2>&1; then
    if [[ "$CREATE_PROJECT_IF_MISSING" == "true" ]]; then
      log "Project does not exist; creating: $PROJECT_ID"
      gcloud projects create "$PROJECT_ID" --name="OpenClaw Gateway"
    else
      fatal "Project does not exist and auto-create is disabled."
    fi
  fi
  gcloud config set project "$PROJECT_ID" >/dev/null

  if [[ -n "$BILLING_ACCOUNT_ID" ]]; then
    log "Linking billing account..."
    gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT_ID"
  fi

  log "Enabling required APIs..."
  gcloud services enable compute.googleapis.com dns.googleapis.com aiplatform.googleapis.com

  log "Ensuring static external IP exists..."
  if ! gcloud compute addresses describe "$STATIC_IP_NAME" --region "$REGION" >/dev/null 2>&1; then
    gcloud compute addresses create "$STATIC_IP_NAME" --region "$REGION"
  fi
  local STATIC_IP
  STATIC_IP=$(gcloud compute addresses describe "$STATIC_IP_NAME" --region "$REGION" --format='value(address)')
  [[ -z "$STATIC_IP" ]] && fatal "Failed to resolve static IP address."

  log "Ensuring firewall rule exists..."
  if ! gcloud compute firewall-rules describe "$FIREWALL_RULE_NAME" >/dev/null 2>&1; then
    gcloud compute firewall-rules create "$FIREWALL_RULE_NAME" \
      --direction=INGRESS \
      --priority=1000 \
      --network=default \
      --action=ALLOW \
      --rules="tcp:22,tcp:80,tcp:443,tcp:${OPENCLAW_GATEWAY_PORT}" \
      --source-ranges=0.0.0.0/0 \
      --target-tags="$INSTANCE_TAG" \
      --description="Allow SSH/HTTP/HTTPS/OpenClaw inbound traffic"
  fi

  local vm_exists="false"
  if gcloud compute instances describe "$VM_NAME" --zone "$ZONE" >/dev/null 2>&1; then
    vm_exists="true"
    log "VM already exists: $VM_NAME"
  fi

  if [[ "$vm_exists" == "false" ]]; then
    log "Creating VM..."
    gcloud compute instances create "$VM_NAME" \
      --zone="$ZONE" \
      --machine-type="$MACHINE_TYPE" \
      --boot-disk-size="$BOOT_DISK_SIZE" \
      --image-family=debian-12 \
      --image-project=debian-cloud \
      --address="$STATIC_IP" \
      --scopes=cloud-platform \
      --tags="$INSTANCE_TAG"
  else
    local existing_ip
    existing_ip=$(gcloud compute instances describe "$VM_NAME" --zone "$ZONE" --format='value(networkInterfaces[0].accessConfigs[0].natIP)')
    if [[ -z "$existing_ip" ]]; then
      log "VM has no external IP; attaching reserved static IP..."
      gcloud compute instances add-access-config "$VM_NAME" --zone "$ZONE" --address "$STATIC_IP"
    elif [[ "$existing_ip" != "$STATIC_IP" ]]; then
      warn "VM external IP is $existing_ip (reserved IP is $STATIC_IP). DNS will use the VM IP."
      STATIC_IP="$existing_ip"
    fi
  fi

  wait_for_ssh "$VM_NAME" "$ZONE"

  if [[ "$ENABLE_PUBLIC_URL" == "true" && "$MANAGE_DNS_RECORD" == "true" ]]; then
    log "Configuring Cloud DNS A record..."
    if ! gcloud dns managed-zones describe "$DNS_ZONE_NAME" >/dev/null 2>&1; then
      if [[ "$CREATE_DNS_ZONE_IF_MISSING" == "true" ]]; then
        [[ -z "$DNS_ZONE_DNS_NAME" ]] && fatal "DNS_ZONE_DNS_NAME is required to create a zone."
        gcloud dns managed-zones create "$DNS_ZONE_NAME" \
          --dns-name="${DNS_ZONE_DNS_NAME}." \
          --description="$DNS_ZONE_DESCRIPTION"
      else
        fatal "Managed zone '$DNS_ZONE_NAME' does not exist."
      fi
    fi

    local record_fqdn="${PUBLIC_URL_FQDN}."
    if gcloud dns record-sets describe "$record_fqdn" --zone "$DNS_ZONE_NAME" --type A >/dev/null 2>&1; then
      gcloud dns record-sets update "$record_fqdn" \
        --zone "$DNS_ZONE_NAME" \
        --type A \
        --ttl "$DNS_TTL" \
        --rrdatas "$STATIC_IP"
    else
      gcloud dns record-sets create "$record_fqdn" \
        --zone "$DNS_ZONE_NAME" \
        --type A \
        --ttl "$DNS_TTL" \
        --rrdatas "$STATIC_IP"
    fi
  fi

  local TMP_DIR
  TMP_DIR=$(mktemp -d)
  local ENV_FILE="$TMP_DIR/openclaw-deploy.env"
  local REMOTE_SCRIPT_NAME="bootstrap-openclaw-vm.sh"
  local REMOTE_SCRIPT="$TMP_DIR/$REMOTE_SCRIPT_NAME"
  local REMOTE_ENV_FILE="~/openclaw-deploy.env"
  local REMOTE_SCRIPT_FILE="~/$REMOTE_SCRIPT_NAME"

  trap 'rm -rf "$TMP_DIR"' EXIT

  {
    write_env_line OPENCLAW_IMAGE "$OPENCLAW_IMAGE"
    write_env_line OPENCLAW_GATEWAY_TOKEN "$OPENCLAW_GATEWAY_TOKEN"
    write_env_line OPENCLAW_CONFIG_DIR "$OPENCLAW_CONFIG_DIR"
    write_env_line OPENCLAW_WORKSPACE_DIR "$OPENCLAW_WORKSPACE_DIR"
    write_env_line OPENCLAW_GATEWAY_PORT "$OPENCLAW_GATEWAY_PORT"
    write_env_line OPENCLAW_BRIDGE_PORT "$OPENCLAW_BRIDGE_PORT"
    write_env_line OPENCLAW_GATEWAY_HOST_BIND "$OPENCLAW_GATEWAY_HOST_BIND"
    write_env_line OPENCLAW_BRIDGE_HOST_BIND "$OPENCLAW_BRIDGE_HOST_BIND"
    write_env_line OPENCLAW_GATEWAY_BIND "$OPENCLAW_GATEWAY_BIND"
    write_env_line OPENCLAW_AGENT_MODEL "$OPENCLAW_AGENT_MODEL"
    write_env_line OPENROUTER_API_KEY "$OPENROUTER_API_KEY"
    write_env_line OPENROUTER_BASE_URL "$OPENROUTER_BASE_URL"
    write_env_line GEMINI_API_KEY "$GEMINI_API_KEY"
    write_env_line GEMINI_BASE_URL "$GEMINI_BASE_URL"
    write_env_line KIMI_API_KEY "$KIMI_API_KEY"
    write_env_line KIMI_BASE_URL "$KIMI_BASE_URL"
    write_env_line GROQ_API_KEY "$GROQ_API_KEY"
    write_env_line GROQ_BASE_URL "$GROQ_BASE_URL"
    write_env_line R2_ACCESS_KEY_ID "$R2_ACCESS_KEY_ID"
    write_env_line R2_SECRET_ACCESS_KEY "$R2_SECRET_ACCESS_KEY"
    write_env_line KEOTHOM_MCP_API_KEY "$KEOTHOM_MCP_API_KEY"
    write_env_line CLAUDE_AI_SESSION_KEY "$CLAUDE_AI_SESSION_KEY"
    write_env_line CLAUDE_WEB_SESSION_KEY "$CLAUDE_WEB_SESSION_KEY"
    write_env_line CLAUDE_WEB_COOKIE "$CLAUDE_WEB_COOKIE"
    write_env_line PUBLIC_URL_FQDN "$PUBLIC_URL_FQDN"
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"

  cat > "$REMOTE_SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail

APP_DIR=$(shell_quote "$REMOTE_APP_DIR")
REPO_URL=$(shell_quote "$DEPLOY_REPO_URL")
REPO_REF=$(shell_quote "$DEPLOY_REPO_REF")
OPENCLAW_CONFIG_DIR=$(shell_quote "$OPENCLAW_CONFIG_DIR")
OPENCLAW_WORKSPACE_DIR=$(shell_quote "$OPENCLAW_WORKSPACE_DIR")
REMOTE_ENV_FILE=$(shell_quote "$REMOTE_ENV_FILE")
ENABLE_CADDY=$(shell_quote "$ENABLE_CADDY")
PUBLIC_URL_FQDN=$(shell_quote "$PUBLIC_URL_FQDN")
CADDY_EMAIL=$(shell_quote "$CADDY_EMAIL")
OPENCLAW_GATEWAY_PORT=$(shell_quote "$OPENCLAW_GATEWAY_PORT")
OPENCLAW_IMAGE=$(shell_quote "$OPENCLAW_IMAGE")

sudo apt-get update -qq
sudo apt-get install -y -qq ca-certificates curl git gnupg jq >/dev/null

if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sudo sh
fi
sudo usermod -aG docker "\$USER" >/dev/null 2>&1 || true

if [[ -d "\$APP_DIR/.git" ]]; then
  git -C "\$APP_DIR" fetch --all --prune --tags
else
  rm -rf "\$APP_DIR"
  git clone "\$REPO_URL" "\$APP_DIR"
  git -C "\$APP_DIR" fetch --all --prune --tags
fi

if git -C "\$APP_DIR" show-ref --verify --quiet "refs/remotes/origin/\$REPO_REF"; then
  git -C "\$APP_DIR" checkout -B "\$REPO_REF" "origin/\$REPO_REF"
elif git -C "\$APP_DIR" rev-parse --verify "\$REPO_REF^{commit}" >/dev/null 2>&1; then
  git -C "\$APP_DIR" checkout "\$REPO_REF"
else
  DEFAULT_BRANCH=\$(git -C "\$APP_DIR" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)
  if [[ -z "\$DEFAULT_BRANCH" ]]; then
    DEFAULT_BRANCH="main"
  fi
  echo "[WARN] Requested ref '\$REPO_REF' not found; using '\$DEFAULT_BRANCH' instead."
  git -C "\$APP_DIR" checkout -B "\$DEFAULT_BRANCH" "origin/\$DEFAULT_BRANCH" || git -C "\$APP_DIR" checkout "\$DEFAULT_BRANCH"
fi

mkdir -p "\$APP_DIR/custom-skills"
mkdir -p "\$OPENCLAW_CONFIG_DIR" "\$OPENCLAW_WORKSPACE_DIR"
cp "\$REMOTE_ENV_FILE" "\$APP_DIR/.env"
chmod 600 "\$APP_DIR/.env"

# Load provider credentials and endpoint overrides from .env.
set -a
# shellcheck disable=SC1090
source "\$APP_DIR/.env"
set +a

jq -n \
  --arg agent_model "\${OPENCLAW_AGENT_MODEL:-gemini/gemini-3-flash-preview}" \
  --arg openrouter_api_key "\${OPENROUTER_API_KEY:-}" \
  --arg openrouter_base_url "\${OPENROUTER_BASE_URL:-https://openrouter.ai/api/v1}" \
  --arg gemini_api_key "\${GEMINI_API_KEY:-}" \
  --arg gemini_base_url "\${GEMINI_BASE_URL:-https://generativelanguage.googleapis.com/v1beta/openai}" \
  --arg kimi_api_key "\${KIMI_API_KEY:-}" \
  --arg kimi_base_url "\${KIMI_BASE_URL:-https://api.moonshot.cn/v1}" \
  --arg groq_api_key "\${GROQ_API_KEY:-}" \
  --arg groq_base_url "\${GROQ_BASE_URL:-https://api.groq.com/openai/v1}" \
  '
  {
    browser: {
      enabled: true,
      executablePath: "/usr/bin/chromium",
      headless: true,
      noSandbox: true
    },
    models: {
      providers: {
        openrouter: {
          baseUrl: $openrouter_base_url,
          apiKey: $openrouter_api_key,
          api: "openai-completions",
          models: [
            {
              id: "openai/gpt-5-mini",
              name: "GPT-5 Mini (OpenRouter)",
              reasoning: false,
              input: ["text"],
              cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
              contextWindow: 200000,
              maxTokens: 8192
            }
          ]
        },
        gemini: {
          baseUrl: $gemini_base_url,
          apiKey: $gemini_api_key,
          api: "openai-completions",
          models: [
            {
              id: "gemini-3-flash-preview",
              name: "Gemini 3 Flash Preview",
              reasoning: false,
              input: ["text", "image"],
              cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
              contextWindow: 1048576,
              maxTokens: 8192
            },
            {
              id: "gemini-2.5-pro",
              name: "Gemini 2.5 Pro",
              reasoning: false,
              input: ["text", "image"],
              cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
              contextWindow: 1048576,
              maxTokens: 8192
            },
            {
              id: "gemini-2.5-flash",
              name: "Gemini 2.5 Flash",
              reasoning: false,
              input: ["text", "image"],
              cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
              contextWindow: 1048576,
              maxTokens: 8192
            }
          ]
        },
        kimi: {
          baseUrl: $kimi_base_url,
          apiKey: $kimi_api_key,
          api: "openai-completions",
          models: [
            {
              id: "kimi-k2-0905-preview",
              name: "Kimi K2 0905 (Code)",
              reasoning: false,
              input: ["text"],
              cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
              contextWindow: 128000,
              maxTokens: 8192
            }
          ]
        },
        groq: {
          baseUrl: $groq_base_url,
          apiKey: $groq_api_key,
          api: "openai-completions",
          models: [
            {
              id: "openai/gpt-oss-120b",
              name: "GPT-OSS 120B (Groq)",
              reasoning: false,
              input: ["text"],
              cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
              contextWindow: 131072,
              maxTokens: 8192
            }
          ]
        }
      }
    },
    agents: {
      defaults: {
        model: {
          primary: $agent_model,
          fallbacks: ([
            "openrouter/openai/gpt-5-mini",
            "gemini/gemini-3-flash-preview",
            "gemini/gemini-2.5-pro",
            "groq/openai/gpt-oss-120b",
            "kimi/kimi-k2-0905-preview"
          ] | map(select(. != $agent_model)))
        },
        imageModel: {
          primary: "gemini/gemini-3-flash-preview"
        },
        maxConcurrent: 4
      },
      list: [
        { id: "main", default: true, name: "Javis", model: $agent_model },
        { id: "lena", name: "Lena", model: "gemini/gemini-2.5-pro" },
        { id: "marcus", name: "Marcus", model: "groq/openai/gpt-oss-120b" }
      ]
    },
    tools: {
      elevated: {
        enabled: false
      },
      agentToAgent: {
        enabled: true,
        allow: ["main", "lena", "marcus"]
      }
    },
    bindings: [
      { agentId: "main", match: { channel: "telegram", accountId: "javis" } },
      { agentId: "lena", match: { channel: "telegram", accountId: "lena" } },
      { agentId: "marcus", match: { channel: "telegram", accountId: "marcus" } }
    ],
    channels: {
      telegram: {
        enabled: true,
        dmPolicy: "pairing",
        groupPolicy: "allowlist",
        groupAllowFrom: ["@YOUR_TELEGRAM_ADMIN_USERNAME"],
        groups: {
          "*": {
            requireMention: true
          }
        },
        historyLimit: 20,
        linkPreview: false,
        streamMode: "partial",
        accounts: {
          javis: { botToken: "YOUR_JAVIS_BOT_TOKEN" },
          lena: { botToken: "YOUR_LENA_BOT_TOKEN" },
          marcus: { botToken: "YOUR_MARCUS_BOT_TOKEN" }
        }
      }
    },
    gateway: {
      mode: "local",
      controlUi: {
        allowInsecureAuth: false,
        dangerouslyDisableDeviceAuth: false
      },
      trustedProxies: [
        "172.18.0.1",
        "172.16.0.0/12",
        "10.0.0.0/8",
        "192.168.0.0/16",
        "127.0.0.1"
      ]
    }
  }
  ' > "\$OPENCLAW_CONFIG_DIR/openclaw.json"

cd "\$APP_DIR"
if ! sudo docker image inspect "\${OPENCLAW_IMAGE:-openclaw:chromium}" >/dev/null 2>&1; then
  UPSTREAM_DIR="\$HOME/openclaw-upstream"
  if [[ -d "\$UPSTREAM_DIR/.git" ]]; then
    git -C "\$UPSTREAM_DIR" pull --ff-only || true
  else
    git clone https://github.com/openclaw/openclaw.git "\$UPSTREAM_DIR"
  fi
  sudo docker build -t "\${OPENCLAW_IMAGE:-openclaw:chromium}" -f "\$UPSTREAM_DIR/Dockerfile" "\$UPSTREAM_DIR"
fi

sudo docker compose pull || true
sudo docker compose up -d

if [[ "\$ENABLE_CADDY" == "true" ]]; then
  sudo apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https >/dev/null
  if [[ ! -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg ]]; then
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  fi
  if [[ ! -f /etc/apt/sources.list.d/caddy-stable.list ]]; then
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  fi
  sudo apt-get update -qq
  sudo apt-get install -y -qq caddy >/dev/null

  if [[ -n "\$CADDY_EMAIL" ]]; then
    sudo tee /etc/caddy/Caddyfile >/dev/null <<CADDYFILE
{
  email \$CADDY_EMAIL
}
\$PUBLIC_URL_FQDN {
  reverse_proxy 127.0.0.1:\$OPENCLAW_GATEWAY_PORT
}
CADDYFILE
  else
    sudo tee /etc/caddy/Caddyfile >/dev/null <<CADDYFILE
\$PUBLIC_URL_FQDN {
  reverse_proxy 127.0.0.1:\$OPENCLAW_GATEWAY_PORT
}
CADDYFILE
  fi

  sudo systemctl enable caddy >/dev/null
  sudo systemctl restart caddy
fi
EOF
  chmod +x "$REMOTE_SCRIPT"

  log "Copying deployment artifacts to VM..."
  gcloud compute scp --zone "$ZONE" "$ENV_FILE" "$REMOTE_SCRIPT" "${VM_NAME}:~/"

  log "Running VM bootstrap script..."
  gcloud compute ssh "$VM_NAME" --zone "$ZONE" --command "bash $REMOTE_SCRIPT_FILE"

  printf '\n=== Deployment Complete ===\n'
  printf 'VM Name:                %s\n' "$VM_NAME"
  printf 'VM External IP:         %s\n' "$STATIC_IP"
  if [[ "$ENABLE_PUBLIC_URL" == "true" ]]; then
    printf 'Public URL:             https://%s\n' "$PUBLIC_URL_FQDN"
    if [[ "$MANAGE_DNS_RECORD" == "false" ]]; then
      printf 'Manual DNS step:        Create A record %s -> %s\n' "$PUBLIC_URL_FQDN" "$STATIC_IP"
    fi
    if [[ "$ENABLE_CADDY" == "false" ]]; then
      printf 'Proxy note:             Caddy is disabled. Expose and secure the gateway yourself.\n'
    fi
  else
    printf 'Gateway URL:            http://%s:%s\n' "$STATIC_IP" "$OPENCLAW_GATEWAY_PORT"
  fi
  printf 'Gateway token:          %s\n' "$OPENCLAW_GATEWAY_TOKEN"
  printf '\n'
}

main "$@"
