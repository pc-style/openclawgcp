#!/bin/bash
#
# openclaw-config - CLI for managing OpenClaw configuration on GCP VM
#
# Usage:
#   ./scripts/openclaw-config.sh <command> [options]
#
# Commands:
#   list                List current config (JSON path)
#   get <path>         Get config value at JSON path (e.g., channels.telegram.groupAllowFrom)
#   add <path> <value> Add value to array at path (e.g., channels.telegram.groupAllowFrom "123456")
#   rm <path> <value>  Remove value from array at path
#   reload              Reload config without restarting container (sends SIGHUP)
#   restart             Full restart of all Docker services
#   logs [lines]        Show container logs (default: 50 lines)
#   sync                Sync configs from local to VM
#
# Examples:
#   ./scripts/openclaw-config.sh get channels.telegram.groupAllowFrom
#   ./scripts/openclaw-config.sh add channels.telegram.groupAllowFrom "8153548124"
#   ./scripts/openclaw-config.sh reload
#   ./scripts/openclaw-config.sh logs 100

set -e

VM_NAME="openclaw-gateway"
ZONE="us-central1-a"
VM_USER="pcstyle"
CONFIG_FILE="/home/pcstyle/.openclaw/openclaw.json"
CONTAINER_NAME="openclaw-gateway"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

ssh_exec() {
    gcloud compute ssh "$VM_NAME" --zone="$ZONE" --command="$1"
}

# Get config value
cmd_get() {
    local path="$1"
    if [ -z "$path" ]; then
        log_error "Usage: $0 get <json-path>"
        exit 1
    fi
    log_info "Getting config at: $path"
    ssh_exec "cat $CONFIG_FILE | jq '.$path'"
}

# List available config paths
cmd_list() {
    log_info "Available config sections:"
    ssh_exec "cat $CONFIG_FILE | jq 'keys'"
}

# Add value to array
cmd_add() {
    local path="$1"
    local value="$2"
    if [ -z "$path" ] || [ -z "$value" ]; then
        log_error "Usage: $0 add <json-path> <value>"
        exit 1
    fi
    log_info "Adding '$value' to $path"
    ssh_exec "jq '.$path += [\"$value\"]' $CONFIG_FILE > /tmp/openclaw_temp.json && mv /tmp/openclaw_temp.json $CONFIG_FILE"
    log_info "Config updated. Run '$0 reload' to apply changes."
}

# Remove value from array
cmd_rm() {
    local path="$1"
    local value="$2"
    if [ -z "$path" ] || [ -z "$value" ]; then
        log_error "Usage: $0 rm <json-path> <value>"
        exit 1
    fi
    log_info "Removing '$value' from $path"
    ssh_exec "jq '.$path -= [\"$value\"]' $CONFIG_FILE > /tmp/openclaw_temp.json && mv /tmp/openclaw_temp.json $CONFIG_FILE"
    log_info "Config updated. Run '$0 reload' to apply changes."
}

# Reload config (graceful)
cmd_reload() {
    log_info "Reloading config (sending SIGHUP to container)..."
    ssh_exec "docker exec $CONTAINER_NAME kill -HUP 1"
    sleep 2
    log_info "Checking logs..."
    ssh_exec "docker logs $CONTAINER_NAME --tail 10"
}

# Full restart
cmd_restart() {
    log_info "Restarting all services..."
    ssh_exec "cd ~/openclaw && docker compose restart"
    sleep 3
    cmd_status
}

# Show logs
cmd_logs() {
    local lines="${1:-50}"
    log_info "Showing last $lines lines of logs:"
    ssh_exec "docker logs $CONTAINER_NAME --tail $lines"
}

# Show status
cmd_status() {
    log_info "Service status:"
    ssh_exec "cd ~/openclaw && docker compose ps"
}

# Sync config from local to VM
cmd_sync() {
    local local_config="configs/openclaw.json"
    if [ ! -f "$local_config" ]; then
        log_error "Local config not found: $local_config"
        exit 1
    fi
    log_info "Syncing $local_config to VM..."
    gcloud compute scp "$local_config" "$VM_NAME:$CONFIG_FILE" --zone="$ZONE" 2>/dev/null
    log_info "Config synced. Run '$0 reload' to apply changes."
}

# Show help
cmd_help() {
    echo "OpenClaw Config CLI"
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  list                List available config sections"
    echo "  get <path>         Get config value at JSON path"
    echo "  add <path> <value> Add value to array at path"
    echo "  rm <path> <value>  Remove value from array"
    echo "  reload              Reload config without restart (SIGHUP)"
    echo "  restart             Full Docker restart"
    echo "  logs [lines]        Show container logs"
    echo "  status              Show service status"
    echo "  sync                Sync local config to VM"
    echo ""
    echo "Examples:"
    echo "  $0 get channels.telegram.groupAllowFrom"
    echo "  $0 add channels.telegram.groupAllowFrom 8153548124"
    echo "  $0 rm channels.telegram.groupAllowFrom @username"
    echo "  $0 reload"
    echo "  $0 logs 100"
}

# Main
case "${1:-help}" in
    list) cmd_list ;;
    get) cmd_get "$2" ;;
    add) cmd_add "$2" "$3" ;;
    rm) cmd_rm "$2" "$3" ;;
    reload) cmd_reload ;;
    restart) cmd_restart ;;
    logs) cmd_logs "$2" ;;
    status) cmd_status ;;
    sync) cmd_sync ;;
    help|--help|-h) cmd_help ;;
    *) log_error "Unknown command: $1"; cmd_help; exit 1 ;;
esac
