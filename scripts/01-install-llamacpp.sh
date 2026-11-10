#!/usr/bin/env bash
# Step 1 — llama.cpp with CUDA support.
# Prefer the latest prebuilt CUDA release binary from ggml-org/llama.cpp;
# fall back to building from source with cmake -DGGML_CUDA=ON.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# --- fast path: already installed with Qwen3.8 reasoning controls ------------
supports_qwen38() {
  local help
  help="$("$1" --help 2>&1)" || return 1
  grep -q -- '--reasoning-effort' <<<"$help" && \
    grep -q -- '--reasoning-preserve' <<<"$help"
}

if command -v llama-server >/dev/null 2>&1 && llama-server --version >/dev/null 2>&1; then
  if supports_qwen38 "$(command -v llama-server)"; then
    log_ok "llama-server already installed: $(llama-server --version | head -1)"
    exit 0
  fi
  log_warn "Existing llama-server lacks the reasoning controls required by Qwen3.8 — upgrading."
fi
if [ -x "$LLAMA_DIR/bin/llama-server" ]; then
  if supports_qwen38 "$LLAMA_DIR/bin/llama-server"; then
    log_ok "llama-server already present at $LLAMA_DIR/bin"
    sudo ln -sf "$LLAMA_DIR"/bin/llama-* /usr/local/bin/ 2>/dev/null || true
    exit 0
  fi
  log_warn "Managed llama.cpp installation is too old for Qwen3.8 — upgrading."
fi

# Avoid selecting stale binaries from an older managed installation.
rm -rf "$LLAMA_DIR"

sudo apt-get update
apt_install curl unzip jq ca-certificates

install_prebuilt() {
  log_info "Fetching latest ggml-org/llama.cpp release metadata…"
  # NOTE: /releases/latest no longer points at a binary release on
  # ggml-org/llama.cpp — scan recent releases for one that actually ships a
  # CUDA Ubuntu binary. Assets are now .tar.gz with names like:
  #   llama-<tag>-bin-ubuntu-cuda-12.8-x64.tar.gz
  #   cudart-llama-<tag>-bin-ubuntu-cuda-12.8-x64.tar.gz
  local api="https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=10"
  local releases; releases="$(curl -fsSL "$api")" || return 1

  local tag bin_url cudart_url
  while read -r t; do
    [ -n "$t" ] || continue
    bin_url="$(echo "$releases" | jq -r --arg t "$t" \
      '.[] | select(.tag_name==$t) | .assets[].browser_download_url' \
      | grep -E '/llama-[^/]+-bin-ubuntu-cuda-[0-9.]+-x64\.tar\.gz$' | head -1)"
    [ -n "$bin_url" ] || continue
    cudart_url="$(echo "$releases" | jq -r --arg t "$t" \
      '.[] | select(.tag_name==$t) | .assets[].browser_download_url' \
      | grep -E 'cudart-llama-.*-bin-ubuntu-cuda-[0-9.]+-x64\.tar\.gz$' | head -1)"
    tag="$t"; break
  done < <(echo "$releases" | jq -r '.[].tag_name')

  if [ -z "${tag:-}" ] || [ -z "${bin_url:-}" ]; then
    log_warn "No release with a CUDA Ubuntu binary found in the last 10 releases."
    return 1
  fi
  log_info "Using release $tag: $(basename "$bin_url")"

  local tmp; tmp="$(mktemp -d)"
  mkdir -p "$LLAMA_DIR"

  if ! curl -fSL -o "$tmp/llama.tar.gz" "$bin_url"; then
    log_warn "Failed to download $bin_url"; rm -rf "$tmp"; return 1
  fi
  mkdir -p "$tmp/x" && tar -xzf "$tmp/llama.tar.gz" -C "$tmp/x"
  cp -r "$tmp/x"/. "$LLAMA_DIR/"

  if [ -n "${cudart_url:-}" ]; then
    log_info "Downloading bundled CUDA runtime: $(basename "$cudart_url")"
    if curl -fSL -o "$tmp/cudart.tar.gz" "$cudart_url"; then
      mkdir -p "$tmp/cudart" && tar -xzf "$tmp/cudart.tar.gz" -C "$tmp/cudart"
      cp -r "$tmp/cudart"/*/. "$LLAMA_DIR/" 2>/dev/null || cp -r "$tmp/cudart"/. "$LLAMA_DIR/"
    else
      log_warn "cudart bundle failed to download; relying on system CUDA runtime."
    fi
  fi
  rm -rf "$tmp"

  # llama.cpp archives place binaries under build/bin, bin, or a flat
  # llama-<tag>/ dir depending on release — locate llama-server wherever it is.
  local found bindir
  found="$(find "$LLAMA_DIR" -name llama-server -type f | head -1)"
  [ -n "$found" ] || { log_warn "llama-server not found in release archive."; return 1; }
  bindir="$(dirname "$found")"

  chmod +x "$bindir"/llama-* 2>/dev/null || true
  sudo ln -sf "$bindir"/llama-* /usr/local/bin/
  # bundled .so files (libggml, libcudart, …) live next to the binaries
  echo "$bindir" | sudo tee /etc/ld.so.conf.d/llama-cpp.conf >/dev/null
  sudo ldconfig

  # Recent prebuilts target Ubuntu 24.04+ (glibc 2.38) — on 22.04 they fail
  # with GLIBC_2.38 / GLIBCXX_3.4.32 errors. Detect that and fall back to a
  # source build instead of leaving broken binaries behind.
  if ! "$bindir/llama-server" --version >/dev/null 2>&1; then
    log_warn "Prebuilt binary cannot run on this system (glibc too old?) — cleaning up."
    sudo rm -f /usr/local/bin/llama-* /etc/ld.so.conf.d/llama-cpp.conf
    sudo ldconfig
    rm -rf "$LLAMA_DIR"
    return 1
  fi
  return 0
}

build_from_source() {
  log_info "Building llama.cpp from source with CUDA…"
  apt_install build-essential cmake git libcurl4-openssl-dev ccache
  # gcc/g++ version skew breaks nvcc (gcc 12 + g++ 11 → cc1plus execvp error).
  # Ensure a matching cc1plus exists for the default gcc.
  local gcc_ver; gcc_ver="$(gcc -dumpversion)"
  if [ ! -e "/usr/lib/gcc/x86_64-linux-gnu/$gcc_ver/cc1plus" ]; then
    log_info "gcc is $gcc_ver but g++-$gcc_ver is missing — installing it."
    apt_install "g++-$gcc_ver" || apt_install g++
  fi
  # Prefer an existing /usr/local/cuda toolkit over apt's outdated one.
  local cuda_bin=""
  for d in /usr/local/cuda/bin /usr/local/cuda-*/bin; do
    [ -x "$d/nvcc" ] && cuda_bin="$d" && break
  done
  if [ -n "$cuda_bin" ]; then
    export PATH="$cuda_bin:$PATH"
    log_info "Using nvcc from $cuda_bin ($(nvcc --version | tail -1))"
  elif ! command -v nvcc >/dev/null 2>&1; then
    apt_install nvidia-cuda-toolkit
  fi
  # Fresh clone if needed (wipe leftovers from a failed prebuilt attempt).
  if [ ! -d "$LLAMA_DIR/.git" ]; then
    rm -rf "$LLAMA_DIR"
    git clone --depth 1 https://github.com/ggml-org/llama.cpp "$LLAMA_DIR"
  fi
  rm -rf "$LLAMA_DIR/build"   # clean any failed configure cache
  # Build only for the GPU(s) actually present — the default "all
  # architectures" multiplies flash-attention template compile time by ~7.
  local cuda_arch=""
  local cc; cc="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr -d ' .')"
  if [ -n "$cc" ]; then
    cuda_arch="$cc"
    log_info "Detected GPU compute capability → CMAKE_CUDA_ARCHITECTURES=$cuda_arch"
  else
    cuda_arch="86;89;90"
    log_warn "Could not detect compute capability — using '$cuda_arch'."
  fi
  cmake -S "$LLAMA_DIR" -B "$LLAMA_DIR/build" -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CUDA_ARCHITECTURES="$cuda_arch" \
    ${cuda_bin:+-DCMAKE_CUDA_COMPILER="$cuda_bin/nvcc"}
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
