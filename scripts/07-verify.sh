#!/usr/bin/env bash
# Verify actual responses instead of matching words in agent output.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_ubuntu_2204
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

wait_http() {
  local url="$1" deadline=$((SECONDS + $2))
  until curl -fsS --max-time 5 -o /dev/null "$url"; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 5
  done
}
sudo systemctl start llama-cyberstrike hexstrike hexstrike-bridge
wait_http "http://127.0.0.1:$LLAMA_PORT/health" 600
wait_http "http://127.0.0.1:$HEXSTRIKE_PORT/health" 300
python3 "$REPO_ROOT/scripts/verify_stack.py" --model-port "$LLAMA_PORT" --model-alias "$MODEL_ALIAS" --mcp-port "$HEXSTRIKE_MCP_BRIDGE_PORT"
systemctl is-active --quiet llama-watchdog.timer
log_ok "API, inference, tools, MCP execution and watchdog checks passed."

# Verify the configured agent can complete a request through the local provider.
cd "$STACK_HOME"
AGENT_OUTPUT="$(mktemp)"
trap 'rm -f "$AGENT_OUTPUT"' EXIT
PRIVATE_FLAGS=()
OPENCODE_BIN=opencode
if command -v npm >/dev/null 2>&1; then
  NPM_PREFIX="$(sudo npm prefix -g 2>/dev/null || true)"
  if [ -n "$NPM_PREFIX" ] && [ -x "$NPM_PREFIX/bin/opencode" ]; then
    OPENCODE_BIN="$NPM_PREFIX/bin/opencode"
  fi
fi
RUN_HELP="$("$OPENCODE_BIN" run --help 2>&1)"
if grep -q -- '--standalone' <<<"$RUN_HELP"; then PRIVATE_FLAGS+=(--standalone); fi
if ! timeout 600 "$OPENCODE_BIN" run "${PRIVATE_FLAGS[@]}" --auto --model "local/$MODEL_ALIAS" --format json "Reply with exactly OK. Do not use tools." > "$AGENT_OUTPUT"; then
  cat "$AGENT_OUTPUT"
  log_error "OpenCode could not complete a local model request."
  exit 1
fi
python3 - "$AGENT_OUTPUT" <<'PY'
import json, sys
texts = []
for line in open(sys.argv[1], encoding="utf-8"):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("type") == "error":
        raise SystemExit(f"OpenCode error: {event}")
    if event.get("type") == "text":
        texts.append(event.get("part", {}).get("text", ""))
if not "".join(texts).strip():
    raise SystemExit("OpenCode returned no final text")
print("[OK] OpenCode completed a local inference request")
PY

# Verify the model actually reaches the tools through OpenCode, not just the
# bridge directly. Code Mode exposes them through the `execute` tool.
log_info "Checking that $MODEL_NAME can call a HexStrike tool through OpenCode..."
TOOL_OUTPUT="$(mktemp)"
trap 'rm -f "$AGENT_OUTPUT" "$TOOL_OUTPUT"' EXIT
if ! timeout 1200 "$OPENCODE_BIN" run "${PRIVATE_FLAGS[@]}" --auto --model "local/$MODEL_ALIAS" --format json \
     "Use the HexStrike MCP nmap_scan tool to scan 127.0.0.1 port $LLAMA_PORT. Do not guess: call the tool, then state whether the port is open." > "$TOOL_OUTPUT"; then
  cat "$TOOL_OUTPUT"
  log_error "OpenCode could not run a tool-calling request with $MODEL_ALIAS."
  exit 1
fi
python3 - "$TOOL_OUTPUT" <<'PY'
import json, sys
used_tool = False
saw_hexstrike = False
texts = []
for line in open(sys.argv[1], encoding="utf-8"):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("type") == "error":
        raise SystemExit(f"OpenCode error: {event}")
    if event.get("type") == "tool_use":
        part = event.get("part", {})
        name = part.get("tool", "")
        blob = json.dumps(part)
        used_tool = True
        if name.startswith("hexstrike_") or name == "execute" or "hexstrike" in blob:
            saw_hexstrike = True
    elif event.get("type") == "text":
        texts.append(event.get("part", {}).get("text", ""))
answer = "".join(texts).lower()
if not used_tool:
    raise SystemExit("The model answered without calling any tool")
if "open" not in answer:
    raise SystemExit(f"Tool result was not reported: {answer[:400]}")
print("[OK] OpenCode invoked a tool with the local model"
      + (" via the HexStrike MCP path" if saw_hexstrike else ""))
PY
log_ok "ALL CHECKS PASSED"
