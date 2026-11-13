#!/usr/bin/env bash
# Step 3 — install & start the llama-cyberstrike systemd service, then verify
# the selected model's OpenAI-compatible API.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_ubuntu_2204

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MODEL_FILE="$MODEL_PATH"
[ -f "$MODEL_FILE" ] || { log_error "$MODEL_FILENAME not found in $MODELS_DIR — run step 2 first."; exit 1; }

LLAMA_BIN="$(command -v llama-server || true)"
[ -n "$LLAMA_BIN" ] || { log_error "llama-server not on PATH — run step 1 first."; exit 1; }
LLAMA_LIBDIR="$(dirname "$LLAMA_BIN")"
# /usr/local/bin is a symlink farm; resolve to the real lib dir.
LLAMA_LIBDIR="$(dirname "$(readlink -f "$LLAMA_BIN")")"

unit_dir=/etc/systemd/system
model_unit=llama-cyberstrike.service
backup_dir="$(mktemp -d)"
rollback=0
model_was_active=0
timer_was_active=0
systemctl is-active --quiet "$model_unit" && model_was_active=1
systemctl is-active --quiet llama-watchdog.timer && timer_was_active=1

cleanup() {
  local status=$? unit
  if [ "$rollback" = 1 ]; then
    log_warn "Restoring previous inference service configuration."
    for unit in "$model_unit" llama-watchdog.service llama-watchdog.timer; do
      if [ -f "$backup_dir/$unit" ]; then
        sudo install -m 0644 "$backup_dir/$unit" "$unit_dir/$unit" || log_error "Could not restore $unit."
      else
        if [ -f "$unit_dir/$unit" ] && systemctl is-enabled --quiet "$unit"; then
          sudo systemctl disable "$unit" || log_error "Could not disable $unit."
        fi
        sudo rm -f "$unit_dir/$unit" || log_error "Could not remove $unit."
      fi
    done
    sudo systemctl daemon-reload || log_error "Could not reload restored units."
    if [ "$model_was_active" = 1 ]; then
      sudo systemctl restart "$model_unit" || log_error "Could not restart previous model."
    else
      sudo systemctl stop "$model_unit" || log_error "Could not stop model service."
    fi
    if [ "$timer_was_active" = 1 ]; then
      sudo systemctl start llama-watchdog.timer || log_error "Could not restart watchdog timer."
    fi
  fi
  rm -f "$backup_dir/"*
  rmdir "$backup_dir"
  return "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for unit in "$model_unit" llama-watchdog.service llama-watchdog.timer; do
  if [ -f "$unit_dir/$unit" ]; then
    cp "$unit_dir/$unit" "$backup_dir/$unit"
  fi
done

log_info "Generating systemd unit (user=$STACK_USER, model=$MODEL_NAME)"
sed -e "s|__STACK_USER__|$STACK_USER|g" \
    -e "s|__STACK_GROUP__|$STACK_GROUP|g" \
    -e "s|__LLAMA_BIN__|$LLAMA_BIN|g" \
    -e "s|__STACK_HOME__|$STACK_HOME|g" \
    -e "s|__MODEL_FILE__|$MODEL_FILE|g" \
    -e "s|__MODEL_ALIAS__|$MODEL_ALIAS|g" \
    -e "s|__MODEL_HOST__|$MODEL_HOST|g" \
    -e "s|__MODEL_PORT__|$LLAMA_PORT|g" \
    -e "s|__MODEL_CONTEXT__|$MODEL_CONTEXT|g" \
    -e "s|__LLAMA_LIBDIR__|$LLAMA_LIBDIR|g" \
    "$REPO_ROOT/systemd/llama-cyberstrike.service" \
  > "$backup_dir/model.next"
sed "/^\[Service\]/a Environment=PHARAOH_INFERENCE_PORT=$LLAMA_PORT" \
  "$REPO_ROOT/systemd/llama-watchdog.service" > "$backup_dir/watchdog.next"

rollback=1
if [ -f "$backup_dir/llama-watchdog.timer" ]; then
  sudo systemctl stop llama-watchdog.timer llama-watchdog.service
fi
sudo install -m 0644 "$backup_dir/model.next" "$unit_dir/$model_unit"
sudo install -D -m 0644 "$REPO_ROOT/scripts/llama_watchdog.py" /usr/local/lib/pharaoh/llama_watchdog.py
sudo install -m 0644 "$backup_dir/watchdog.next" "$unit_dir/llama-watchdog.service"
sudo install -m 0644 "$REPO_ROOT/systemd/llama-watchdog.timer" "$unit_dir/"
sudo systemctl daemon-reload
sudo systemctl restart llama-cyberstrike

# --- wait for the model to load ------------------------------------------------
log_info "Waiting for llama-server on :$LLAMA_PORT (model load can take a while)…"
for _ in $(seq 1 120); do
  if curl -fsS --max-time 5 "http://localhost:$LLAMA_PORT/health" >/dev/null 2>&1; then
    break
  fi
  if ! systemctl is-active --quiet llama-cyberstrike; then
    log_error "Service died while loading. Recent logs:"
    sudo journalctl -u llama-cyberstrike -n 40 --no-pager
    exit 1
  fi
  sleep 5
done

log_info "Checking model alias via GET /v1/models:"
curl -fsS --max-time 10 "http://localhost:$LLAMA_PORT/v1/models" |
  python3 -c 'import json,sys; ids=[m["id"] for m in json.load(sys.stdin)["data"]]; print(ids); sys.exit(sys.argv[1] not in ids)' "$MODEL_ALIAS"

log_info "Chat completion smoke test ('say OK')…"
RESP="$(curl -fsS --max-time 180 "http://localhost:$LLAMA_PORT/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"$MODEL_ALIAS\",\"messages\":[{\"role\":\"user\",\"content\":\"say OK\"}],\"chat_template_kwargs\":{\"enable_thinking\":false},\"max_tokens\":32}")"
echo "$RESP" | python3 -m json.tool
if ! echo "$RESP" | python3 -c 'import json,sys; m=json.load(sys.stdin)["choices"][0]["message"]; assert (m.get("content") or "").strip(), "empty content"'; then
  log_error "Chat completion returned empty content."
  exit 1
fi

sudo systemctl enable "$model_unit" llama-watchdog.timer
sudo systemctl start llama-watchdog.timer
rollback=0
log_ok "llama-cyberstrike is serving $MODEL_NAME as '$MODEL_ALIAS' on http://$MODEL_HOST:$LLAMA_PORT/v1"
