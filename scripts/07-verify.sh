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
python3 "$REPO_ROOT/scripts/verify_stack.py"
systemctl is-active --quiet llama-watchdog.timer
log_ok "API, inference, tools, MCP execution and watchdog checks passed."

# Verify the configured agent can complete a request through the local provider.
cd "$STACK_HOME"
AGENT_OUTPUT="$(mktemp)"
trap 'rm -f "$AGENT_OUTPUT"' EXIT
PRIVATE_FLAGS=()
if opencode run --help 2>&1 | grep -q -- '--standalone'; then PRIVATE_FLAGS+=(--standalone); fi
if ! timeout 600 opencode run "${PRIVATE_FLAGS[@]}" --model "local/$MODEL_ALIAS" --format json "Reply with exactly OK. Do not use tools." > "$AGENT_OUTPUT"; then
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
log_ok "ALL CHECKS PASSED"
