#!/usr/bin/env bash
# Step 5 — install opencode and wire it to the local CyberStrike model
# (OpenAI-compatible on :8000) + HexStrike MCP (stdio bridge to :8888).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- Node.js (needed for npm install -g opencode-ai) --------------------------
if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
  log_info "Installing Node.js LTS (NodeSource)…"
  curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
  apt_install nodejs
fi
log_info "Node $(node --version) / npm $(npm --version)"

# --- opencode ------------------------------------------------------------------
if ! command -v opencode >/dev/null 2>&1; then
  log_info "Installing opencode-ai globally…"
  if ! sudo npm install -g opencode-ai; then
    log_warn "npm install failed — trying the official install script."
    curl -fsSL https://opencode.ai/install | bash
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
sed -e "s|__HEXSTRIKE_DIR__|$HEXSTRIKE_DIR|g" \
    "$REPO_ROOT/config/opencode.json" > "$OPENCODE_CONFIG_DIR/opencode.json"
log_ok "Wrote $OPENCODE_CONFIG_DIR/opencode.json"
cat "$OPENCODE_CONFIG_DIR/opencode.json"

# sanity: the stdio bridge entry point must exist
[ -f "$HEXSTRIKE_DIR/hexstrike_mcp.py" ] || \
  log_warn "hexstrike_mcp.py not found — check the HexStrike repo layout; adjust 'mcp' in opencode.json if its README uses a different entry point."

log_ok "opencode is configured: model=local/cyberstrike, mcp=hexstrike"
