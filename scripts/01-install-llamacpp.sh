#!/usr/bin/env bash
# Step 1 — llama.cpp with CUDA support.
# Prefer the latest prebuilt CUDA release binary from ggml-org/llama.cpp;
# fall back to building from source with cmake -DGGML_CUDA=ON.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# --- fast path: already installed ------------------------------------------
if command -v llama-server >/dev/null 2>&1 && llama-server --version >/dev/null 2>&1; then
  log_ok "llama-server already installed: $(llama-server --version | head -1)"
  exit 0
fi
if [ -x "$LLAMA_DIR/bin/llama-server" ]; then
  log_ok "llama-server already present at $LLAMA_DIR/bin"
  sudo ln -sf "$LLAMA_DIR"/bin/llama-* /usr/local/bin/ 2>/dev/null || true
  exit 0
fi

sudo apt-get update
apt_install curl unzip jq ca-certificates

install_prebuilt() {
  log_info "Fetching latest ggml-org/llama.cpp release metadata…"
  local api="https://api.github.com/repos/ggml-org/llama.cpp/releases/latest"
  local tag; tag="$(curl -fsSL "$api" | jq -r .tag_name)"
  [ -n "$tag" ] && [ "$tag" != "null" ] || return 1
  log_info "Latest release: $tag"

  local base="https://github.com/ggml-org/llama.cpp/releases/download/$tag"
  local tmp; tmp="$(mktemp -d)"

  # Ubuntu binary zip (name has been stable: llama-<tag>-bin-ubuntu-x64.zip)
  if ! curl -fSL -o "$tmp/llama.zip" "$base/llama-$tag-bin-ubuntu-x64.zip"; then
    log_warn "Prebuilt ubuntu-x64 asset not found for $tag."
    rm -rf "$tmp"; return 1
  fi

  # CUDA runtime bundle (needed unless full CUDA toolkit is installed).
  local cudart_url
  cudart_url="$(curl -fsSL "$api" | jq -r '.assets[].browser_download_url' \
                | grep -E 'cudart-llama-bin-.*(linux|ubuntu).*\.zip' | head -1 || true)"

  mkdir -p "$LLAMA_DIR"
  unzip -qo "$tmp/llama.zip" -d "$tmp/x"
  cp -r "$tmp/x"/. "$LLAMA_DIR/"

  if [ -n "$cudart_url" ]; then
    log_info "Downloading bundled CUDA runtime: $(basename "$cudart_url")"
    curl -fSL -o "$tmp/cudart.zip" "$cudart_url" \
      && unzip -qo "$tmp/cudart.zip" -d "$tmp/cudart" \
      && cp -r "$tmp/cudart"/. "$LLAMA_DIR/" || \
      log_warn "cudart bundle failed to install; relying on system CUDA runtime."
  fi
  rm -rf "$tmp"

  # llama.cpp zips place binaries under build/bin or bin depending on release.
  local bindir
  bindir="$(dirname "$(find "$LLAMA_DIR" -name llama-server -type f | head -1)")"
  [ -n "$bindir" ] || { log_warn "llama-server not found in release zip."; return 1; }

  chmod +x "$bindir"/llama-* 2>/dev/null || true
  sudo ln -sf "$bindir"/llama-* /usr/local/bin/
  # bundled .so files live next to the binaries
  echo "$bindir" | sudo tee /etc/ld.so.conf.d/llama-cpp.conf >/dev/null
  sudo ldconfig
  return 0
}

build_from_source() {
  log_info "Building llama.cpp from source with CUDA…"
  apt_install build-essential cmake git libcurl4-openssl-dev ccache
  if ! command -v nvcc >/dev/null 2>&1; then
    apt_install nvidia-cuda-toolkit
  fi
  [ -d "$LLAMA_DIR/.git" ] || git clone --depth 1 https://github.com/ggml-org/llama.cpp "$LLAMA_DIR"
  cmake -S "$LLAMA_DIR" -B "$LLAMA_DIR/build" -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release
  cmake --build "$LLAMA_DIR/build" --config Release -j"$(nproc)"
  sudo ln -sf "$LLAMA_DIR"/build/bin/llama-* /usr/local/bin/
}

if ! install_prebuilt; then
  log_warn "Prebuilt install failed — falling back to source build."
  build_from_source
fi

log_info "Verifying binary…"
llama-server --version
log_ok "llama.cpp ready: $(command -v llama-server)"
