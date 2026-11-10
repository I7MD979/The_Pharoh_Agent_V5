#!/usr/bin/env bash
# Step 5 — install opencode and wire it to the local Qwen3.8 agentic model
# (OpenAI-compatible on :8000) + HexStrike MCP (remote streamable-http bridge daemon).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_ubuntu_2204
bootstrap

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- Node.js (needed for npm install -g opencode-ai) --------------------------
if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1 || \
   ! node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 22 ? 0 : 1)'; then
  log_info "Installing Node.js LTS (NodeSource)…"
  NODE_SETUP="$(mktemp)"
  curl -fsSL --retry 3 https://deb.nodesource.com/setup_22.x -o "$NODE_SETUP"
  sudo -E bash "$NODE_SETUP"
  rm -f "$NODE_SETUP"
  apt_install nodejs
fi
log_info "Node $(node --version) / npm $(npm --version)"

# --- opencode ------------------------------------------------------------------
if ! command -v opencode >/dev/null 2>&1; then
  log_info "Installing opencode-ai globally…"
  if ! sudo npm install -g opencode-ai; then
    log_warn "npm install failed — trying the official install script."
    OC_SETUP="$(mktemp)"
    curl -fsSL --retry 3 https://opencode.ai/install -o "$OC_SETUP"
    bash "$OC_SETUP"
    rm -f "$OC_SETUP"
    export PATH="$STACK_HOME/.opencode/bin:$PATH"
  fi
fi
command -v opencode >/dev/null 2>&1 || {
  # npm global bin may not be on PATH in this shell — locate it.
  NPM_PREFIX="$(npm config get prefix)"
  export PATH="$NPM_PREFIX/bin:$PATH"
}
command -v opencode >/dev/null 2>&1 || { log_error "opencode not found after install."; exit 1; }
log_ok "opencode: $(command -v opencode)"

# --- config --------------------------------------------------------------------
mkdir -p "$OPENCODE_CONFIG_DIR"
[ ! -f "$OPENCODE_CONFIG_DIR/opencode.json" ] || \
  cp -p "$OPENCODE_CONFIG_DIR/opencode.json" "$OPENCODE_CONFIG_DIR/opencode.json.backup.$(date +%Y%m%d%H%M%S).$$"
sed -e "s|__HEXSTRIKE_DIR__|$HEXSTRIKE_DIR|g" \
    -e "s|__HEXSTRIKE_MCP_BRIDGE_PORT__|$HEXSTRIKE_MCP_BRIDGE_PORT|g" \
    -e "s|__MODEL_ALIAS__|$MODEL_ALIAS|g" \
    "$REPO_ROOT/config/opencode.json" > "$OPENCODE_CONFIG_DIR/opencode.json"
log_ok "Wrote $OPENCODE_CONFIG_DIR/opencode.json"
python3 -m json.tool "$OPENCODE_CONFIG_DIR/opencode.json" >/dev/null
opencode --version

# sanity: the bridge daemon must exist (serves MCP over streamable-http) and
# the HexStrike entry point it wraps must be present.
[ -f "$HEXSTRIKE_DIR/hexstrike_mcp.py" ] || \
  log_warn "hexstrike_mcp.py not found — check the HexStrike repo layout; adjust 'mcp' in opencode.json if its README uses a different entry point."

if bash -c "</dev/tcp/127.0.0.1/$HEXSTRIKE_MCP_BRIDGE_PORT" 2>/dev/null; then
  log_ok "MCP bridge is listening on http://127.0.0.1:$HEXSTRIKE_MCP_BRIDGE_PORT/mcp"
else
  log_warn "MCP bridge not reachable on :$HEXSTRIKE_MCP_BRIDGE_PORT yet ($(systemctl is-active hexstrike-bridge 2>/dev/null || echo 'service not installed?')). Re-run step 4 to install it."
fi

log_ok "opencode is configured: model=local/$MODEL_ALIAS, mcp=hexstrike (remote @ :$HEXSTRIKE_MCP_BRIDGE_PORT)"
