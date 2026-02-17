#!/usr/bin/env bash
#
# openclaw-ops - Day-2 ops for the OpenClaw GCP VM (status/logs/health/sync).
#
# Usage:
#   ./scripts/openclaw-ops.sh <command> [args]
#
# Env overrides:
#   VM_NAME=openclaw-gateway
#   ZONE=us-central1-a
#   REMOTE_APP_CURRENT_DIR=~/openclawgcp/current
#   REMOTE_CONFIG_FILE=~/.openclaw/openclaw.json
#   CONTAINER_NAME=openclaw-gateway
#
set -euo pipefail

VM_NAME="${VM_NAME:-openclaw-gateway}"
ZONE="${ZONE:-us-central1-a}"
REMOTE_APP_CURRENT_DIR="${REMOTE_APP_CURRENT_DIR:-~/openclawgcp/current}"
REMOTE_CONFIG_FILE="${REMOTE_CONFIG_FILE:-~/.openclaw/openclaw.json}"
CONTAINER_NAME="${CONTAINER_NAME:-openclaw-gateway}"

log() { printf '[INFO] %s\n' "$1"; }
warn() { printf '[WARN] %s\n' "$1" >&2; }
fatal() { printf '[ERROR] %s\n' "$1" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fatal "Missing required command: $1"
}

ssh_exec() {
  gcloud compute ssh "$VM_NAME" --zone="$ZONE" --command="$1"
}

scp_to_vm() {
  local src="$1"
  local dest="$2"
  gcloud compute scp --zone="$ZONE" "$src" "${VM_NAME}:${dest}"
}

cmd_status() {
  log "Service status"
  ssh_exec "cd ${REMOTE_APP_CURRENT_DIR} && sudo docker compose ps"
}

cmd_logs() {
  local lines="${1:-50}"
  log "Logs (last ${lines} lines)"
  ssh_exec "sudo docker logs ${CONTAINER_NAME} --tail ${lines}"
}

cmd_health() {
  log "Gateway health (probing /_health then /health)"
  ssh_exec "
set -euo pipefail
PORT=\$(cd ${REMOTE_APP_CURRENT_DIR} && set -a && source ./.env >/dev/null 2>&1 || true; set +a; echo \${OPENCLAW_GATEWAY_PORT:-18789})
for path in /_health /health; do
  code=\$(curl -sS -o /tmp/oc-health-body -w '%{http_code}' --max-time 5 http://127.0.0.1:\${PORT}\${path} || true)
  if [[ \"\$code\" != \"000\" ]]; then
    echo \"\${path}: \${code}\"
    head -c 400 /tmp/oc-health-body || true
    echo
    exit 0
  fi
done
echo \"health probe failed\"
exit 1
"
}

cmd_restart() {
  log "Restarting OpenClaw service"
  ssh_exec "cd ${REMOTE_APP_CURRENT_DIR} && sudo docker compose restart openclaw"
  cmd_status
}

cmd_sync_config() {
  local local_config="configs/openclaw.json"
  [[ -f "$local_config" ]] || fatal "Local config not found: $local_config"
  log "Syncing ${local_config} -> ${REMOTE_CONFIG_FILE}"
  scp_to_vm "$local_config" "$REMOTE_CONFIG_FILE"
  cmd_restart
}

cmd_telegram_check() {
  log "Telegram getMe (uses TELEGRAM_BOT_TOKEN from remote .env)"
  ssh_exec "
set -euo pipefail
cd ${REMOTE_APP_CURRENT_DIR}
set -a
source ./.env
set +a
if [[ -z \"\${TELEGRAM_BOT_TOKEN:-}\" ]]; then
  echo \"TELEGRAM_BOT_TOKEN is not set in .env\"
  exit 1
fi
curl -fsSL --max-time 10 \"https://api.telegram.org/bot\${TELEGRAM_BOT_TOKEN}/getMe\" | head -c 2000
echo
"
}

cmd_help() {
  cat <<EOF
openclaw-ops

Usage:
  $0 <command> [args]

Commands:
  status               docker compose ps (remote)
  logs [lines]         docker logs openclaw-gateway --tail <lines>
  health               curl localhost health endpoint on the VM
  restart              docker compose restart openclaw
  sync-config          scp configs/openclaw.json -> ~/.openclaw/openclaw.json, then restart
  telegram-check       call Telegram getMe from the VM using TELEGRAM_BOT_TOKEN in .env

Env:
  VM_NAME, ZONE, REMOTE_APP_CURRENT_DIR, REMOTE_CONFIG_FILE, CONTAINER_NAME
EOF
}

main() {
  require_cmd gcloud
  case "${1:-help}" in
    status) cmd_status ;;
    logs) cmd_logs "${2:-50}" ;;
    health) cmd_health ;;
    restart) cmd_restart ;;
    sync-config) cmd_sync_config ;;
    telegram-check) cmd_telegram_check ;;
    help|-h|--help) cmd_help ;;
    *) warn "Unknown command: ${1:-}"; cmd_help; exit 1 ;;
  esac
}

main "$@"

