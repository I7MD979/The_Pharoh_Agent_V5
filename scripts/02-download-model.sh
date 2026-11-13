#!/usr/bin/env bash
# Step 2 — download and validate the selected Q8_0 GGUF.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_ubuntu_2204
apt_install python3-venv
mkdir -p "$MODELS_DIR"

# Keep HF dependencies separate from system Python (PEP 668 on Ubuntu 24.04).
HF_VENV="$STACK_HOME/.local/share/pharaoh/hf-venv"
if [ ! -x "$HF_VENV/bin/hf" ]; then
  python3 -m venv "$HF_VENV"
  retry 3 "$HF_VENV/bin/python" -m pip install --upgrade 'huggingface-hub>=0.34,<2'
fi

EXPECTED_SIZE="$("$HF_VENV/bin/python" - "$HF_REPO" "$MODEL_FILENAME" <<'PY'
import sys
from huggingface_hub import get_hf_file_metadata, hf_hub_url
meta = get_hf_file_metadata(hf_hub_url(sys.argv[1], sys.argv[2]))
if not meta.size:
    raise SystemExit("Could not determine model download size")
print(meta.size)
PY
)"

valid_model() {
  python3 - "$MODEL_PATH" "$EXPECTED_SIZE" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
if not p.is_file() or p.stat().st_size != int(sys.argv[2]):
    sys.exit(1)
with p.open('rb') as f:
    sys.exit(0 if f.read(4) == b'GGUF' else 1)
PY
}

if valid_model; then
  log_ok "Model already present:"
  ls -lh "$MODEL_PATH"
  exit 0
fi

export HF_XET_HIGH_PERFORMANCE="${HF_XET_HIGH_PERFORMANCE:-1}"

download() {
  local flags=()
  [ ! -f "$MODEL_PATH" ] || flags+=(--force-download)
  "$HF_VENV/bin/hf" download "$HF_REPO" "$MODEL_FILENAME" --local-dir "$MODELS_DIR" "${flags[@]}" || return 1
  valid_model || {
    log_error "$MODEL_FILENAME was not produced by the download."
    return 1
  }
}

log_info "Downloading $HF_REPO/$MODEL_FILENAME ($EXPECTED_SIZE bytes) → $MODELS_DIR"
retry 3 download

[ -f "$MODEL_PATH" ] || { log_error "Model download produced no Q8_0 GGUF file."; exit 1; }
log_ok "Model ready: $MODEL_PATH ($(du -h "$MODEL_PATH" | cut -f1))"
