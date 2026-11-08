#!/usr/bin/env bash
# Step 7 — end-to-end verification. All checks must pass.
#   1. llama.cpp: chat completion "say OK" returns text
#   2. HexStrike: tool list includes nmap, nuclei, sqlmap
#   3. opencode: non-interactive run lists MCP tools
#   4. real test: nmap scan of scanme.nmap.org through the agent
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

FAILURES=0
check() { # check <name> <ok:0/1>
  if [ "$2" -eq 0 ]; then log_ok "$1"; else log_error "$1"; FAILURES=$((FAILURES+1)); fi
}

# wait_http <url> <max-seconds> — poll until the endpoint answers HTTP 200.
# Services (especially llama.cpp loading a 35 GB model) need time on first start.
wait_http() {
  local url="$1" max="$2" elapsed=0
  until curl -fsS -o /dev/null -m 5 "$url" 2>/dev/null; do
    elapsed=$((elapsed + 5))
    if [ "$elapsed" -ge "$max" ]; then return 1; fi
    sleep 5
  done
}

# --- 1. llama.cpp ---------------------------------------------------------------
log_banner "1/4 llama.cpp chat completion"
systemctl is-active --quiet llama-cyberstrike || sudo systemctl start llama-cyberstrike
if wait_http "http://localhost:$LLAMA_PORT/v1/models" 600; then
  log_info "llama.cpp is up — sending test completion"
else
  log_error "llama.cpp did not respond on port $LLAMA_PORT within 10 minutes"
fi
RESP="$(curl -fsS "http://localhost:$LLAMA_PORT/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"cyberstrike","messages":[{"role":"user","content":"say OK"}],"max_tokens":16}' 2>/dev/null || true)"
echo "$RESP" | grep -q '"content"'
check "llama.cpp 'say OK' returned text" $?

# --- 2. HexStrike tool list -------------------------------------------------------
log_banner "2/4 HexStrike tool list"
systemctl is-active --quiet hexstrike || sudo systemctl start hexstrike
if wait_http "http://localhost:$HEXSTRIKE_PORT/health" 300; then
  log_info "HexStrike is up — checking exposed tools"
else
  log_error "HexStrike did not respond on port $HEXSTRIKE_PORT within 5 minutes"
fi
TOOLS="$(curl -fsS "http://localhost:$HEXSTRIKE_PORT/api/tools" 2>/dev/null || \
         curl -fsS "http://localhost:$HEXSTRIKE_PORT/health" 2>/dev/null || true)"
HEX_OK=0
for t in nmap nuclei sqlmap; do
  echo "$TOOLS" | grep -qi "$t" || HEX_OK=1
done
check "HexStrike exposes nmap / nuclei / sqlmap" $HEX_OK

# --- 3. opencode MCP listing -------------------------------------------------------
log_banner "3/4 opencode MCP tool listing"
NPM_PREFIX="$(npm config get prefix 2>/dev/null || true)"
export PATH="$NPM_PREFIX/bin:$STACK_HOME/.opencode/bin:$PATH"
cd "$STACK_HOME"  # run outside the repo so opencode uses ~/.config/opencode
MCP_OK=1
for attempt in 1 2 3; do
  MCP_OUT="$(timeout 180 opencode run \
    "List the tools provided by the hexstrike MCP server (for example hexstrike_nmap_scan, hexstrike_nuclei_scan, hexstrike_sqlmap_scan). Do not read or write any local files — just list the MCP tool names." \
    2>&1 || true)"
  echo "$MCP_OUT" | tail -20
  if echo "$MCP_OUT" | grep -Eiq 'nmap|nuclei|sqlmap|hexstrike'; then
    MCP_OK=0; break
  fi
  log_warn "MCP listing attempt $attempt/3 gave no usable answer — retrying"
done
check "opencode lists HexStrike MCP tools" $MCP_OK

# --- 4. real scan test ---------------------------------------------------------------
log_banner "4/4 real nmap scan via agent (scanme.nmap.org)"
SCAN_OK=1
for attempt in 1 2 3; do
  SCAN_OUT="$(timeout 420 opencode run \
    "Call the hexstrike_nmap_scan MCP tool with target=scanme.nmap.org and scan_type=-sV, then summarize the open ports from the tool result. Do not read or write any local files — use the MCP tool directly." \
    2>&1 || true)"
  echo "$SCAN_OUT" | tail -30
  if echo "$SCAN_OUT" | grep -Eiq 'open|PORT|22/tcp|80/tcp'; then
    SCAN_OK=0; break
  fi
  log_warn "scan attempt $attempt/3 failed — retrying"
done
check "agent ran real nmap scan through MCP" $SCAN_OK

# --- summary ---------------------------------------------------------------------------
log_banner "Verification summary"
if [ "$FAILURES" -eq 0 ]; then
  log_ok "ALL CHECKS PASSED — the stack is fully operational."
else
  log_error "$FAILURES check(s) failed — see above, then re-run ./scripts/07-verify.sh"
  exit 1
fi
