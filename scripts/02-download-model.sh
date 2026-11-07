#!/usr/bin/env bash
# Step 2 — download Huihui-CyberStrike-OffSec-35B-abliterated GGUF (Q4_K_M only).
# Skips the MTP speculative-decoding weights and any mmproj extras on purpose.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

mkdir -p "$MODELS_DIR"

if compgen -G "$MODELS_DIR/*Q4_K_M*.gguf" >/dev/null; then
  log_ok "Q4_K_M model already present:"
  ls -lh "$MODELS_DIR"/*Q4_K_M*.gguf
  exit 0
fi

# --- huggingface-hub CLI -----------------------------------------------------
if ! command -v huggingface-cli >/dev/null 2>&1 && ! command -v hf >/dev/null 2>&1; then
  log_info "Installing huggingface-hub CLI…"
  apt_install python3-pip python3-venv
  pip3 install --upgrade --user huggingface-hub hf_transfer || \
    pip3 install --upgrade --user --break-system-packages huggingface-hub || true
  export PATH="$STACK_HOME/.local/bin:$PATH"
fi

export HF_HUB_ENABLE_HF_TRANSFER="${HF_HUB_ENABLE_HF_TRANSFER:-1}"

download() {
  if command -v hf >/dev/null 2>&1; then
    hf download "$HF_REPO" --include "*Q4_K_M*" --local-dir "$MODELS_DIR"
  else
    huggingface-cli download "$HF_REPO" --include "*Q4_K_M*" --local-dir "$MODELS_DIR"
  fi
}

log_info "Downloading $HF_REPO (Q4_K_M only, ~21 GB) → $MODELS_DIR"
retry 3 download

# Flatten in case the CLI preserved the repo subfolder layout.
find "$MODELS_DIR" -mindepth 2 -name '*Q4_K_M*.gguf' -exec mv -n {} "$MODELS_DIR/" \; 2>/dev/null || true

MODEL_FILE="$(find "$MODELS_DIR" -maxdepth 1 -name '*Q4_K_M*.gguf' | head -1)"
[ -n "$MODEL_FILE" ] || { log_error "Model download produced no Q4_K_M .gguf file."; exit 1; }

log_ok "Model ready: $MODEL_FILE ($(du -h "$MODEL_FILE" | cut -f1))"
