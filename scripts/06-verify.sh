#!/usr/bin/env bash
# Step 6 — end-to-end verification. All checks must pass.
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

# --- 1. llama.cpp ---------------------------------------------------------------
log_banner "1/4 llama.cpp chat completion"
systemctl is-active --quiet llama-cyberstrike || sudo systemctl start llama-cyberstrike
RESP="$(curl -fsS "http://localhost:$LLAMA_PORT/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"cyberstrike","messages":[{"role":"user","content":"say OK"}],"max_tokens":16}' 2>/dev/null || true)"
echo "$RESP" | grep -q '"content"'
check "llama.cpp 'say OK' returned text" $?

# --- 2. HexStrike tool list -------------------------------------------------------
log_banner "2/4 HexStrike tool list"
systemctl is-active --quiet hexstrike || sudo systemctl start hexstrike
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
MCP_OUT="$(timeout 180 opencode run "list your available MCP tools" 2>&1 || true)"
echo "$MCP_OUT" | tail -20
echo "$MCP_OUT" | grep -Eiq 'nmap|nuclei|sqlmap|hexstrike'
check "opencode lists HexStrike MCP tools" $?

# --- 4. real scan test ---------------------------------------------------------------
log_banner "4/4 real nmap scan via agent (scanme.nmap.org)"
SCAN_OUT="$(timeout 420 opencode run \
  "run a quick nmap -sV scan against scanme.nmap.org and summarize open ports" 2>&1 || true)"
echo "$SCAN_OUT" | tail -30
echo "$SCAN_OUT" | grep -Eiq 'open|PORT|22/tcp|80/tcp'
check "agent ran real nmap scan through MCP" $?

# --- summary ---------------------------------------------------------------------------
log_banner "Verification summary"
if [ "$FAILURES" -eq 0 ]; then
  log_ok "ALL CHECKS PASSED — the stack is fully operational."
else
  log_error "$FAILURES check(s) failed — see above, then re-run ./scripts/06-verify.sh"
  exit 1
fi
