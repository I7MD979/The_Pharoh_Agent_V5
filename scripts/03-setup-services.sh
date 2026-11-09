#!/usr/bin/env bash
# Step 3 — install & start the llama-cyberstrike systemd service, then verify
# the OpenAI-compatible API on port 8000.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MODEL_FILE="$MODEL_PATH"
[ -f "$MODEL_FILE" ] || { log_error "$MODEL_FILENAME not found in $MODELS_DIR — run step 2 first."; exit 1; }

LLAMA_BIN="$(command -v llama-server || true)"
[ -n "$LLAMA_BIN" ] || { log_error "llama-server not on PATH — run step 1 first."; exit 1; }
LLAMA_LIBDIR="$(dirname "$LLAMA_BIN")"
# /usr/local/bin is a symlink farm; resolve to the real lib dir.
LLAMA_LIBDIR="$(dirname "$(readlink -f "$LLAMA_BIN")")"

log_info "Generating systemd unit (user=$STACK_USER, model=$MODEL_NAME)"
sed -e "s|__STACK_USER__|$STACK_USER|g" \
    -e "s|__STACK_HOME__|$STACK_HOME|g" \
    -e "s|__MODEL_FILE__|$MODEL_FILE|g" \
    -e "s|__MODEL_ALIAS__|$MODEL_ALIAS|g" \
    -e "s|__LLAMA_LIBDIR__|$LLAMA_LIBDIR|g" \
    "$REPO_ROOT/systemd/llama-cyberstrike.service" \
  | sudo tee /etc/systemd/system/llama-cyberstrike.service >/dev/null

sudo systemctl daemon-reload
# restart (not just enable --now) so a re-run actually applies changed flags
sudo systemctl enable llama-cyberstrike
sudo systemctl restart llama-cyberstrike

# --- wait for the model to load ------------------------------------------------
log_info "Waiting for llama-server on :$LLAMA_PORT (model load can take a while)…"
for i in $(seq 1 60); do
  if curl -fsS "http://localhost:$LLAMA_PORT/v1/models" >/dev/null 2>&1; then
    break
  fi
  if ! systemctl is-active --quiet llama-cyberstrike; then
    log_error "Service died while loading. Recent logs:"
    sudo journalctl -u llama-cyberstrike -n 40 --no-pager
    exit 1
  fi
  sleep 5
done

log_info "GET /v1/models:"
curl -fsS "http://localhost:$LLAMA_PORT/v1/models" | python3 -m json.tool

log_info "Chat completion smoke test ('say OK') with xhigh reasoning…"
RESP="$(curl -fsS "http://localhost:$LLAMA_PORT/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"$MODEL_ALIAS\",\"messages\":[{\"role\":\"user\",\"content\":\"say OK\"}],\"max_tokens\":512}")"
echo "$RESP" | python3 -m json.tool
if ! echo "$RESP" | python3 -c 'import json,sys; m=json.load(sys.stdin)["choices"][0]["message"]; assert (m.get("content") or "").strip(), "empty content"'; then
  log_error "Chat completion returned empty content."
  exit 1
fi

log_ok "llama-cyberstrike is serving $MODEL_NAME as '$MODEL_ALIAS' on http://0.0.0.0:$LLAMA_PORT"
