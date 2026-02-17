#!/bin/bash
# =============================================================================
# Camoufox Anti-Detect Browser Setup for OpenClaw Gateway Container
# =============================================================================
# Installs Camoufox (Firefox-based anti-detect browser) into the OpenClaw
# gateway container for stealth web browsing that bypasses anti-bot systems.
#
# Usage:
#   ./scripts/setup-camoufox.sh [container_name]
#
# Default container: openclaw-openclaw-gateway-1
# =============================================================================

set -euo pipefail

CONTAINER=${1:-openclaw-openclaw-gateway-1}
echo "🦊 Installing Camoufox into container: $CONTAINER"

# --- Step 1: System dependencies ---
echo "[1/3] Installing system dependencies (xvfb, gtk, etc.)..."
docker exec -u root "$CONTAINER" bash -c '
  apt-get update -qq && \
  apt-get install -y -qq \
    xvfb \
    libgtk-3-0 \
    libx11-xcb1 \
    libasound2 \
    dbus-x11 \
  2>&1 | tail -3
'

# --- Step 2: Python package ---
echo "[2/3] Installing camoufox Python package..."
docker exec -u root "$CONTAINER" bash -c '
  pip install -U --break-system-packages camoufox[geoip] 2>&1 | tail -5
'

# --- Step 3: Fetch Firefox binary + GeoIP ---
echo "[3/3] Fetching Camoufox Firefox binary (~713MB)..."
docker exec -u root "$CONTAINER" bash -c '
  python3 -m camoufox fetch 2>&1
'

# --- Verify ---
echo ""
echo "✅ Camoufox installed! Running verification test..."
docker exec "$CONTAINER" python3 -c "
from camoufox.sync_api import Camoufox
with Camoufox(headless='virtual', humanize=True) as browser:
    page = browser.new_page()
    page.goto('https://httpbin.org/headers', timeout=30000)
    page.wait_for_load_state('networkidle')
    import json
    text = page.inner_text('body')
    headers = json.loads(text)
    ua = headers['headers']['User-Agent']
    print(f'User-Agent: {ua}')
    print('🦊 Camoufox test PASSED!')
"

echo ""
echo "=== Usage ==="
echo "Agents can use Camoufox via Python scripts inside the container:"
echo ""
echo "  from camoufox.sync_api import Camoufox"
echo "  with Camoufox(headless='virtual', humanize=True) as browser:"
echo "      page = browser.new_page()"
echo "      page.goto('https://example.com')"
echo ""
echo "Modes: headless=True (basic), headless='virtual' (Xvfb, stealth)"
