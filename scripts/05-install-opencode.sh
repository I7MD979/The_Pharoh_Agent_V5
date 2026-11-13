#!/usr/bin/env bash
# Step 5 — install opencode and wire it to the selected local model
# (OpenAI-compatible on :8000 for Qwen or :8001 for CyberStrike) and the
# HexStrike MCP tools (remote streamable-http bridge daemon on :8890).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_ubuntu_2204
bootstrap

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- Node.js (needed for the OpenCode npm installer) -------------------------
if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1 || \
   ! node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 22 ? 0 : 1)'; then
  log_info "Installing Node.js LTS (NodeSource)…"
  NODE_SETUP="$(mktemp)"
  curl -fsSL --retry 3 https://deb.nodesource.com/setup_22.x -o "$NODE_SETUP"
  sudo -H bash "$NODE_SETUP"
  rm -f "$NODE_SETUP"
  apt_install nodejs
fi
log_info "Node $(node --version) / npm $(npm --version)"

# --- opencode ------------------------------------------------------------------
NPM_PREFIX="$(sudo npm prefix -g)"
NPM_ROOT="$(sudo npm root -g)"
if [ -f "$NPM_ROOT/opencode-ai/package.json" ]; then
  log_info "Removing the legacy npm package before upgrading OpenCode."
  sudo npm uninstall -g opencode-ai
fi
log_info "Installing the latest stable OpenCode CLI…"
sudo npm install -g --prefer-online @opencode/cli@latest
OPENCODE_BIN="$NPM_PREFIX/bin/opencode"
[ -x "$OPENCODE_BIN" ] || { log_error "OpenCode executable missing at $OPENCODE_BIN"; exit 1; }
log_ok "OpenCode $("$OPENCODE_BIN" --version) at $OPENCODE_BIN"

# --- config --------------------------------------------------------------------
mkdir -p "$OPENCODE_CONFIG_DIR"
[ ! -f "$OPENCODE_CONFIG_DIR/opencode.json" ] || \
  cp -p "$OPENCODE_CONFIG_DIR/opencode.json" "$OPENCODE_CONFIG_DIR/opencode.json.backup.$(date +%Y%m%d%H%M%S).$$"
sed -e "s|__HEXSTRIKE_DIR__|$HEXSTRIKE_DIR|g" \
    -e "s|__HEXSTRIKE_MCP_BRIDGE_PORT__|$HEXSTRIKE_MCP_BRIDGE_PORT|g" \
    -e "s|__MODEL_PORT__|$LLAMA_PORT|g" \
    -e "s|__MODEL_ALIAS__|$MODEL_ALIAS|g" \
    -e "s|__MODEL_NAME__|$MODEL_NAME|g" \
    -e "s|__MODEL_CONTEXT__|$MODEL_CONTEXT|g" \
    -e "s|__MODEL_OUTPUT__|$MODEL_OUTPUT|g" \
    -e "s|__PROVIDER_NAME__|$PROVIDER_NAME|g" \
    "$REPO_ROOT/config/opencode.json" > "$OPENCODE_CONFIG_DIR/opencode.json"
log_ok "Wrote $OPENCODE_CONFIG_DIR/opencode.json"
python3 -m json.tool "$OPENCODE_CONFIG_DIR/opencode.json" >/dev/null

# Record the exact binary: a second installation in ~/.opencode/bin or another
# account can otherwise open a different CLI with different settings.
LAUNCHER="$(mktemp)"
sed -e "s|__STACK_USER__|$STACK_USER|g" \
    -e "s|__STACK_HOME__|$STACK_HOME|g" \
    -e "s|__OPENCODE_BIN__|$OPENCODE_BIN|g" \
    -e "s|__MODEL_REF__|local/$MODEL_ALIAS|g" \
    "$REPO_ROOT/scripts/pharaoh.sh" > "$LAUNCHER"
sudo install -m 0755 "$LAUNCHER" /usr/local/bin/pharaoh
rm -f "$LAUNCHER"
log_ok "Installed launcher: pharaoh (account=$STACK_USER, binary=$OPENCODE_BIN)"

log_info "Checking that OpenCode discovers the local model…"
MODEL_FLAGS=()
MODEL_HELP="$("$OPENCODE_BIN" models --help 2>&1)"
if grep -q -- '--standalone' <<<"$MODEL_HELP"; then MODEL_FLAGS+=(--standalone); fi
MODELS_OUTPUT="$(cd "$STACK_HOME" && OPENCODE_CONFIG="$OPENCODE_CONFIG_DIR/opencode.json" \
  timeout 60 "$OPENCODE_BIN" models "${MODEL_FLAGS[@]}" 2>&1)" || {
  log_error "OpenCode could not load the local provider: $MODELS_OUTPUT"; exit 1; }
if ! grep -Fxq "local/$MODEL_ALIAS" <<<"$MODELS_OUTPUT"; then
  log_error "Local model is missing from OpenCode's catalog: $MODELS_OUTPUT"
  exit 1
fi
if ! curl -fsS --max-time 10 "http://127.0.0.1:$LLAMA_PORT/v1/models" | \
     jq -e --arg id "$MODEL_ALIAS" 'any(.data[]; .id == $id)' >/dev/null; then
  log_warn "Model is configured in OpenCode, but llama.cpp is not serving $MODEL_ALIAS on this host. Check systemctl status llama-cyberstrike."
fi

# sanity: the bridge daemon must exist (serves MCP over streamable-http) and
# the HexStrike entry point it wraps must be present.
[ -f "$HEXSTRIKE_DIR/hexstrike_mcp.py" ] || \
  log_warn "hexstrike_mcp.py not found — check the HexStrike repo layout; adjust 'mcp' in opencode.json if its README uses a different entry point."

if bash -c "</dev/tcp/127.0.0.1/$HEXSTRIKE_MCP_BRIDGE_PORT" 2>/dev/null; then
  log_ok "MCP bridge is listening on http://127.0.0.1:$HEXSTRIKE_MCP_BRIDGE_PORT/mcp"
  # Plain `mcp list` reads the generated profile and reports per-server state.
  # Do not add --standalone: 2.2.6 prints "No MCP servers configured" there even
  # with a valid project profile.
  MCP_LIST=""
  if MCP_LIST="$(cd "$STACK_HOME" && OPENCODE_CONFIG="$OPENCODE_CONFIG_DIR/opencode.json" \
       timeout 120 "$OPENCODE_BIN" mcp list 2>&1)" && \
     grep 'hexstrike' <<<"$MCP_LIST" | grep -q 'connected'; then
    log_ok "OpenCode lists the hexstrike MCP server as connected"
  else
    log_warn "OpenCode did not report hexstrike connected: ${MCP_LIST:-no output from 'opencode mcp list'}"
  fi
else
  log_warn "MCP bridge not reachable on :$HEXSTRIKE_MCP_BRIDGE_PORT yet ($(systemctl is-active hexstrike-bridge 2>/dev/null || echo 'service not installed?')). Re-run step 4 to install it."
fi

log_ok "opencode is configured: model=local/$MODEL_ALIAS, mcp=hexstrike (remote @ :$HEXSTRIKE_MCP_BRIDGE_PORT)"
log_info "Start with 'pharaoh' to use the installed account/config and avoid managed-server port conflicts."
