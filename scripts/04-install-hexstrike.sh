#!/usr/bin/env bash
# Step 4 — HexStrike AI MCP tools server.
# Clone netcuter/Hexstrike-AI → venv → pip requirements → security tools →
# hexstrike systemd service (hexstrike_server.py on :8888).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

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
  retry 3 "$HEXSTRIKE_DIR/venv/bin/pip" install -r "$HEXSTRIKE_DIR/requirements.txt"
else
  log_warn "requirements.txt not found — installing minimal deps (flask, requests, mcp)."
  "$HEXSTRIKE_DIR/venv/bin/pip" install flask requests mcp
fi

# --- security tools ------------------------------------------------------------
# Apt-available tools (per HexStrike README). Missing ones are warnings, not
# fatal — the server still exposes whatever is installed.
APT_TOOLS=(nmap sqlmap gobuster hydra john nikto dirb wpscan enum4linux
           metasploit-framework theharvester dnsrecon fierce masscan
           exploitdb commix wafw00f arjun subfinder httpx-toolkit)
TO_INSTALL=()
for t in "${APT_TOOLS[@]}"; do
  pkg="$t"
  [ "$t" = "httpx-toolkit" ] && { command -v httpx >/dev/null 2>&1 && continue; }
  command -v "${t%%-*}" >/dev/null 2>&1 || TO_INSTALL+=("$pkg")
done
if [ "${#TO_INSTALL[@]}" -gt 0 ]; then
  # Most security tools live in universe — make sure it is enabled.
  sudo add-apt-repository -y universe >/dev/null 2>&1 || true
  sudo apt-get update
  # One unknown package name aborts the WHOLE apt-get install — filter first.
  AVAILABLE=()
  for p in "${TO_INSTALL[@]}"; do
    if apt-cache show "$p" >/dev/null 2>&1; then
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
  if ! command -v go >/dev/null 2>&1; then
    log_info "Installing Go (for nuclei)…"
    snap_install_ok=false
    if command -v snap >/dev/null 2>&1 && sudo snap install go --classic 2>/dev/null; then
      snap_install_ok=true
    fi
    $snap_install_ok || apt_install golang-go
  fi
  log_info "Installing nuclei via go install…"
  GOBIN=/usr/local/bin sudo -E "$(command -v go)" install \
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

# --- patch MCP bridge timeouts --------------------------------------------------
# The MCP bridge (hexstrike_mcp.py, spawned by opencode per session) hard-codes
# a 300 s HTTP timeout per request to the HexStrike server. Real scans (nuclei,
# full vulnerability assessments) routinely exceed that → "Timed out, retry."
# Raise it to 30 minutes. Idempotent: only touches the stock default.
if grep -q '^DEFAULT_REQUEST_TIMEOUT = 300' "$HEXSTRIKE_DIR/hexstrike_mcp.py"; then
  sed -i 's/^DEFAULT_REQUEST_TIMEOUT = 300/DEFAULT_REQUEST_TIMEOUT = 1800/' \
    "$HEXSTRIKE_DIR/hexstrike_mcp.py"
  log_ok "Patched hexstrike_mcp.py: request timeout 300s → 1800s"
else
  log_info "hexstrike_mcp.py timeout already patched (or upstream changed) — skipping."
fi

# --- systemd service ------------------------------------------------------------
[ -f "$HEXSTRIKE_DIR/hexstrike_server.py" ] || {
  log_error "hexstrike_server.py not found in $HEXSTRIKE_DIR — repo layout changed?"; exit 1; }

log_info "Generating hexstrike systemd unit…"
sed -e "s|__STACK_USER__|$STACK_USER|g" \
    -e "s|__HEXSTRIKE_DIR__|$HEXSTRIKE_DIR|g" \
    "$REPO_ROOT/systemd/hexstrike.service" \
  | sudo tee /etc/systemd/system/hexstrike.service >/dev/null

sudo systemctl daemon-reload
sudo systemctl enable hexstrike
sudo systemctl restart hexstrike

# --- verify ---------------------------------------------------------------------
log_info "Waiting for HexStrike on :$HEXSTRIKE_PORT…"
for i in $(seq 1 24); do
  curl -fsS "http://localhost:$HEXSTRIKE_PORT/health" >/dev/null 2>&1 && break
  systemctl is-active --quiet hexstrike || {
    log_error "hexstrike service died. Recent logs:"
    sudo journalctl -u hexstrike -n 40 --no-pager; exit 1; }
  sleep 5
done

TOOLS_JSON="$(curl -fsS "http://localhost:$HEXSTRIKE_PORT/api/tools" 2>/dev/null || \
              curl -fsS "http://localhost:$HEXSTRIKE_PORT/health")"
echo "$TOOLS_JSON" | head -c 2000; echo
for t in nmap nuclei sqlmap; do
  echo "$TOOLS_JSON" | grep -qi "$t" && log_ok "tool exposed: $t" \
    || log_warn "'$t' not visible in tool listing (may still be available via MCP bridge)."
done

log_ok "HexStrike AI server is running on http://0.0.0.0:$HEXSTRIKE_PORT"
