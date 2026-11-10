#!/usr/bin/env bash
# Step 4 — HexStrike AI MCP tools server.
# Clone netcuter/Hexstrike-AI → venv → pip requirements → security tools →
# hexstrike systemd service (hexstrike_server.py on :8888).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_ubuntu_2204
bootstrap

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- clone / update -----------------------------------------------------------
if [ -d "$HEXSTRIKE_DIR/.git" ]; then
  log_info "HexStrike repo exists — pulling latest."
  git -C "$HEXSTRIKE_DIR" pull --ff-only || log_warn "git pull failed; keeping current checkout."
else
  retry 3 git clone --depth 1 "$HEXSTRIKE_REPO" "$HEXSTRIKE_DIR"
fi

# --- python venv --------------------------------------------------------------
apt_install python3-venv python3-pip python3-dev git curl
if [ ! -x "$HEXSTRIKE_DIR/venv/bin/python3" ]; then
  log_info "Creating venv…"
  python3 -m venv "$HEXSTRIKE_DIR/venv"
fi
"$HEXSTRIKE_DIR/venv/bin/pip" install --upgrade pip
if [ -f "$HEXSTRIKE_DIR/requirements.txt" ]; then
  # The code imports the official mcp.server.fastmcp, not the third-party
  # fastmcp package. Declare a version with Streamable HTTP explicitly.
  FILTERED="$(mktemp)"
  trap 'rm -f "$FILTERED"' EXIT
  sed '/^[[:space:]]*fastmcp[<=>~![:space:]]/Id' "$HEXSTRIKE_DIR/requirements.txt" > "$FILTERED"
  retry 3 "$HEXSTRIKE_DIR/venv/bin/python" -m pip install -r "$FILTERED" 'mcp>=1.12,<2'
  rm -f "$FILTERED"
  trap - EXIT
else
  log_warn "requirements.txt not found — installing minimal deps (flask, requests, mcp)."
  "$HEXSTRIKE_DIR/venv/bin/pip" install flask requests 'mcp>=1.12,<2'
fi
"$HEXSTRIKE_DIR/venv/bin/python" -m pip check
"$HEXSTRIKE_DIR/venv/bin/python" -c 'from mcp.server.fastmcp import FastMCP; FastMCP("check", stateless_http=True, json_response=True)'

# --- security tools ------------------------------------------------------------
# Apt-available tools (per HexStrike README). Missing ones are warnings, not
# fatal — the server still exposes whatever is installed.
APT_TOOLS=(nmap sqlmap gobuster hydra john nikto dirb wpscan enum4linux
           metasploit-framework theharvester dnsrecon fierce masscan
           exploitdb commix wafw00f arjun subfinder httpx-toolkit)
TO_INSTALL=()
for t in "${APT_TOOLS[@]}"; do
  pkg="$t"
  [ "$t" = "httpx-toolkit" ] && { httpx -version >/dev/null 2>&1 && continue; }
  command -v "${t%%-*}" >/dev/null 2>&1 || TO_INSTALL+=("$pkg")
done
if [ "${#TO_INSTALL[@]}" -gt 0 ]; then
  # Most security tools live in universe — make sure it is enabled.
  sudo add-apt-repository -y universe >/dev/null 2>&1 || true
  sudo apt-get update
  # One unknown package name aborts the WHOLE apt-get install — filter first.
  AVAILABLE=()
  for p in "${TO_INSTALL[@]}"; do
    if pkg_available "$p"; then
      AVAILABLE+=("$p")
    else
      log_warn "Package not in apt repos, skipping: $p"
    fi
  done
  if [ "${#AVAILABLE[@]}" -gt 0 ]; then
    log_info "Installing security tools via apt: ${AVAILABLE[*]}"
    apt_install "${AVAILABLE[@]}"
  fi
fi

# nuclei via Go (README-preferred), fallback to apt/pipx-less download.
if ! command -v nuclei >/dev/null 2>&1; then
  ensure_go
  log_info "Installing nuclei via go install…"
  sudo env GOBIN=/usr/local/bin "$(command -v go)" install \
    github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest 2>/dev/null || {
      log_warn "go install nuclei failed — downloading release binary."
      arch="$(dpkg --print-architecture)"; [ "$arch" = "amd64" ] || arch="arm64"
      nver="$(curl -fsSL https://api.github.com/repos/projectdiscovery/nuclei/releases/latest | jq -r .tag_name)"
      curl -fSL "https://github.com/projectdiscovery/nuclei/releases/download/$nver/nuclei_${nver#v}_linux_$arch.zip" \
        -o /tmp/nuclei.zip && sudo unzip -qo /tmp/nuclei.zip nuclei -d /usr/local/bin/ \
        && sudo chmod +x /usr/local/bin/nuclei
    }
  nuclei -update-templates >/dev/null 2>&1 || true
fi

# Use a separate launcher; leave upstream source intact for git pull.
install -m 0644 "$REPO_ROOT/scripts/hexstrike_bridge.py" "$HEXSTRIKE_DIR/pharaoh_bridge.py"

# --- systemd service ------------------------------------------------------------
[ -f "$HEXSTRIKE_DIR/hexstrike_server.py" ] || {
  log_error "hexstrike_server.py not found in $HEXSTRIKE_DIR — repo layout changed?"; exit 1; }

log_info "Generating hexstrike systemd unit…"
sed -e "s|__STACK_USER__|$STACK_USER|g" \
    -e "s|__STACK_GROUP__|$STACK_GROUP|g" \
    -e "s|__HEXSTRIKE_DIR__|$HEXSTRIKE_DIR|g" \
    "$REPO_ROOT/systemd/hexstrike.service" \
  | sudo tee /etc/systemd/system/hexstrike.service >/dev/null

sudo systemctl daemon-reload
sudo systemctl enable hexstrike
sudo systemctl restart hexstrike

# --- verify ---------------------------------------------------------------------
log_info "Waiting for HexStrike on :$HEXSTRIKE_PORT…"
for _ in $(seq 1 24); do
  curl -fsS --max-time 10 "http://localhost:$HEXSTRIKE_PORT/health" >/dev/null 2>&1 && break
  systemctl is-active --quiet hexstrike || {
    log_error "hexstrike service died. Recent logs:"
    sudo journalctl -u hexstrike -n 40 --no-pager; exit 1; }
  sleep 5
done

TOOLS_JSON="$(curl -fsS --max-time 10 "http://localhost:$HEXSTRIKE_PORT/api/tools" 2>/dev/null || \
              curl -fsS --max-time 10 "http://localhost:$HEXSTRIKE_PORT/health")"
printf '%.2000s\n' "$TOOLS_JSON"
for t in nmap nuclei sqlmap; do
  echo "$TOOLS_JSON" | grep -qi "$t" && log_ok "tool exposed: $t" \
    || log_warn "'$t' not visible in tool listing (may still be available via MCP bridge)."
done

log_ok "HexStrike AI server is running on http://0.0.0.0:$HEXSTRIKE_PORT"

# --- MCP bridge systemd service (streamable-http on :8890) -------------------------
# opencode connects to this URL as `type: remote` — no more stdio child process.
log_info "Generating hexstrike-bridge systemd unit…"
sed -e "s|__STACK_USER__|$STACK_USER|g" \
    -e "s|__STACK_GROUP__|$STACK_GROUP|g" \
    -e "s|__HEXSTRIKE_DIR__|$HEXSTRIKE_DIR|g" \
    "$REPO_ROOT/systemd/hexstrike-bridge.service" \
  | sudo tee /etc/systemd/system/hexstrike-bridge.service >/dev/null

sudo systemctl daemon-reload
sudo systemctl enable hexstrike-bridge
sudo systemctl restart hexstrike-bridge

log_info "Waiting for the MCP bridge on :$HEXSTRIKE_MCP_BRIDGE_PORT…"
for _ in $(seq 1 12); do
  systemctl is-active --quiet hexstrike-bridge || {
    log_error "hexstrike-bridge service died. Recent logs:"
    sudo journalctl -u hexstrike-bridge -n 40 --no-pager; exit 1; }
  BRIDGE_RESP="$(curl -fsS -m 10 -X POST "http://127.0.0.1:$HEXSTRIKE_MCP_BRIDGE_PORT/mcp" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"install-check","version":"0"}}}' 2>/dev/null || true)"
  echo "$BRIDGE_RESP" | grep -q 'hexstrike-ai-mcp' && break
  sleep 3
done

if echo "$BRIDGE_RESP" | grep -q 'hexstrike-ai-mcp'; then
  log_ok "MCP bridge handshake OK on http://127.0.0.1:$HEXSTRIKE_MCP_BRIDGE_PORT/mcp"
else
  log_error "MCP bridge did not answer the MCP handshake on :$HEXSTRIKE_MCP_BRIDGE_PORT. Check: journalctl -u hexstrike-bridge"
  exit 1
fi
