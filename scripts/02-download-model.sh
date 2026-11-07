#!/usr/bin/env bash
# Step 2 — download Huihui-CyberStrike-OffSec-35B-abliterated GGUF.
# Prefers Q4_K_M; the repo may only ship "Q4_K" (the modern name for the
# same Q4_K_M recipe), so fall back to that. Skips mmproj/MTP extras.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

mkdir -p "$MODELS_DIR"

if compgen -G "$MODELS_DIR/*Q4_K*.gguf" >/dev/null; then
  log_ok "Model already present:"
  ls -lh "$MODELS_DIR"/*Q4_K*.gguf
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
  local pattern cli
  if command -v hf >/dev/null 2>&1; then cli="hf"; else cli="huggingface-cli"; fi
  for pattern in "*Q4_K_M*" "*-Q4_K.gguf"; do
    log_info "Trying include pattern: $pattern"
    "$cli" download "$HF_REPO" --include "$pattern" --local-dir "$MODELS_DIR" || true
    # `hf download` exits 0 even when nothing matches — verify a file exists.
    if compgen -G "$MODELS_DIR/*Q4_K*.gguf" >/dev/null || \
       find "$MODELS_DIR" -mindepth 2 -name '*Q4_K*.gguf' | grep -q .; then
      return 0
    fi
  done
  log_error "No Q4_K_M / Q4_K file found in $HF_REPO"
  return 1
}

log_info "Downloading $HF_REPO (Q4_K_M preferred, Q4_K fallback, ~21 GB) → $MODELS_DIR"
retry 3 download

# Flatten in case the CLI preserved the repo subfolder layout.
find "$MODELS_DIR" -mindepth 2 -name '*Q4_K*.gguf' -exec mv -n {} "$MODELS_DIR/" \; 2>/dev/null || true

MODEL_FILE="$(find "$MODELS_DIR" -maxdepth 1 -name '*Q4_K*.gguf' | head -1)"
[ -n "$MODEL_FILE" ] || { log_error "Model download produced no Q4_K .gguf file."; exit 1; }

log_ok "Model ready: $MODEL_FILE ($(du -h "$MODEL_FILE" | cut -f1))"
