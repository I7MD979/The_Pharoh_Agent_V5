#!/usr/bin/env bash
# Step 2 — download Qwen3.8-27B Abliterated (Q8_0 GGUF).
# Q8_0 keeps near-lossless reasoning/tool-calling quality and fits the
# reference 48 GB VRAM GPU with room for the 128K q8_0 KV cache.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

mkdir -p "$MODELS_DIR"

if [ -f "$MODEL_PATH" ]; then
  log_ok "Model already present:"
  ls -lh "$MODEL_PATH"
  exit 0
fi

# --- huggingface-hub CLI -----------------------------------------------------
if ! command -v huggingface-cli >/dev/null 2>&1 && ! command -v hf >/dev/null 2>&1; then
  log_info "Installing huggingface-hub CLI…"
  apt_install python3-pip python3-venv
  pip3 install --upgrade --user huggingface-hub || \
    pip3 install --upgrade --user --break-system-packages huggingface-hub || true
  export PATH="$STACK_HOME/.local/bin:$PATH"
fi
# CLI may exist in ~/.local/bin from a previous run without being on PATH.
command -v hf >/dev/null 2>&1 || command -v huggingface-cli >/dev/null 2>&1 || \
  export PATH="$STACK_HOME/.local/bin:$PATH"

export HF_XET_HIGH_PERFORMANCE="${HF_XET_HIGH_PERFORMANCE:-1}"

download() {
  local cli
  if command -v hf >/dev/null 2>&1; then cli="hf"; else cli="huggingface-cli"; fi
  "$cli" download "$HF_REPO" "$MODEL_FILENAME" --local-dir "$MODELS_DIR"
  [ -f "$MODEL_PATH" ] || {
    log_error "$MODEL_FILENAME was not produced by the download."
    return 1
  }
}

log_info "Downloading $HF_REPO/$MODEL_FILENAME (~29 GB) → $MODELS_DIR"
retry 3 download

[ -f "$MODEL_PATH" ] || { log_error "Model download produced no Q8_0 GGUF file."; exit 1; }
log_ok "Model ready: $MODEL_PATH ($(du -h "$MODEL_PATH" | cut -f1))"
