#!/usr/bin/env bash
# Step 1 — llama.cpp with CUDA support.
# Prefer the latest prebuilt CUDA release binary from ggml-org/llama.cpp;
# fall back to building from source with cmake -DGGML_CUDA=ON.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_ubuntu_2204
bootstrap

# --- fast path: already installed with Qwen3.8 reasoning controls ------------
supports_qwen38() {
  local help
  help="$("$1" --help 2>&1)" || return 1
  grep -q -- '--reasoning-effort' <<<"$help" && \
    grep -q -- '--reasoning-preserve' <<<"$help" && \
    "$1" --list-devices 2>&1 | grep -q CUDA
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

# Preserve previous installs until the replacement has passed validation.
INSTALL_DIR="$LLAMA_DIR"
STAGE="$(mktemp -d "$STACK_HOME/.llama-install.XXXXXX")"
trap 'rm -rf -- "$STAGE"' EXIT
LLAMA_DIR="$STAGE/llama.cpp"

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

  local tag bin_url cudart_url t
  while read -r t; do
    [ -n "$t" ] || continue
    bin_url="$(echo "$releases" | jq -r --arg t "$t" \
      '.[] | select(.tag_name==$t) | .assets[].browser_download_url' \
      | grep -E '/llama-[^/]+-bin-ubuntu-cuda-[0-9.]+-x64\.tar\.gz$' | sed -n '1p' || true)"
    [ -n "$bin_url" ] || continue
    cudart_url="$(echo "$releases" | jq -r --arg t "$t" \
      '.[] | select(.tag_name==$t) | .assets[].browser_download_url' \
      | grep -F "/cudart-$(basename "$bin_url")" | sed -n '1p' || true)"
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
  mkdir -p "$tmp/x" && tar -xzf "$tmp/llama.tar.gz" -C "$tmp/x" || return 1
  cp -r "$tmp/x"/. "$LLAMA_DIR/" || return 1

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
  found="$(find "$LLAMA_DIR" -name llama-server -type f -print -quit)"
  [ -n "$found" ] || { log_warn "llama-server not found in release archive."; return 1; }
  bindir="$(dirname "$found")"
  local lib
  while IFS= read -r -d '' lib; do
    if [ "$(dirname "$lib")" != "$bindir" ]; then
      cp -L "$lib" "$bindir/" || return 1
    fi
  done < <(find "$LLAMA_DIR" -name '*.so*' \( -type f -o -type l \) -print0)

  chmod +x "$bindir"/llama-* 2>/dev/null || true

  # Recent prebuilts target Ubuntu 24.04+ (glibc 2.38) — on 22.04 they fail
  # with GLIBC_2.38 / GLIBCXX_3.4.32 errors. Detect that and fall back to a
  # source build instead of leaving broken binaries behind.
  if ! LD_LIBRARY_PATH="$bindir:${LD_LIBRARY_PATH:-}" "$bindir/llama-server" --version >/dev/null 2>&1 || \
     ! LD_LIBRARY_PATH="$bindir:${LD_LIBRARY_PATH:-}" supports_qwen38 "$bindir/llama-server"; then
    log_warn "Prebuilt binary cannot run on this system (glibc too old?) — cleaning up."
    rm -rf "$LLAMA_DIR"
    return 1
  fi
  return 0
}

build_from_source() {
  log_info "Building llama.cpp from source with CUDA…"
  apt_install build-essential cmake git libcurl4-openssl-dev libssl-dev
  # gcc/g++ version skew breaks nvcc (gcc 12 + g++ 11 → cc1plus execvp error).
  # Ensure a matching cc1plus exists for the default gcc.
  local gcc_ver; gcc_ver="$(gcc -dumpversion)"
  if [ ! -e "/usr/lib/gcc/x86_64-linux-gnu/$gcc_ver/cc1plus" ]; then
    log_info "gcc is $gcc_ver but g++-$gcc_ver is missing — installing it."
    apt_install "g++-$gcc_ver" || apt_install g++
  fi
  # Prefer a complete NVIDIA toolkit, not merely a distro nvcc on PATH.
  local cuda_bin=""
  for d in /usr/local/cuda/bin /usr/local/cuda-*/bin; do
    if [ -x "$d/nvcc" ] && { [ -f "$d/../include/cuda_runtime.h" ] || \
       [ -f "$d/../targets/x86_64-linux/include/cuda_runtime.h" ]; }; then
      cuda_bin="$d"; break
    fi
  done
  if [ -z "$cuda_bin" ]; then
    local repo keyring
    repo="ubuntu$(. /etc/os-release; printf '%s' "${VERSION_ID/./}")"
    keyring="$STAGE/cuda-keyring.deb"
    retry 3 curl -fSL "https://developer.download.nvidia.com/compute/cuda/repos/$repo/x86_64/cuda-keyring_1.1-1_all.deb" -o "$keyring"
    sudo dpkg -i "$keyring"
    sudo apt-get update
    # Does not install/replace NVIDIA drivers or purge the distro toolkit.
    apt_install cuda-toolkit-12-8
    cuda_bin=/usr/local/cuda-12.8/bin
  fi
  if [ -n "$cuda_bin" ]; then
    export PATH="$cuda_bin:$PATH"
    log_info "Using nvcc from $cuda_bin ($(nvcc --version | tail -1))"
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
  local cc; cc="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | tr -d ' .\r' | sort -u | paste -sd ';' - || true)"
  if [ -n "${CUDA_ARCHITECTURES:-$cc}" ]; then
    cuda_arch="${CUDA_ARCHITECTURES:-$cc}"
    log_info "Detected GPU compute capability → CMAKE_CUDA_ARCHITECTURES=$cuda_arch"
  else
    log_error "Cannot detect compute capability. Set CUDA_ARCHITECTURES (for example 86 for Ampere) and retry."
    return 1
  fi
  cmake -S "$LLAMA_DIR" -B "$LLAMA_DIR/build" -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release -DGGML_CCACHE=OFF \
    -DCMAKE_CUDA_ARCHITECTURES="$cuda_arch" \
    -DCMAKE_CUDA_COMPILER="$cuda_bin/nvcc" -DCUDAToolkit_ROOT="$(readlink -f "$cuda_bin/..")"
  cmake --build "$LLAMA_DIR/build" --target llama-server --config Release --parallel "${BUILD_JOBS:-4}"
}

if ! install_prebuilt; then
  log_warn "Prebuilt install failed — falling back to source build."
  build_from_source
fi

log_info "Verifying binary…"
BUILT_BIN="$(find "$LLAMA_DIR" -type f -name llama-server -print -quit)"
[ -n "$BUILT_BIN" ] || { log_error 'Build produced no llama-server.'; exit 1; }
BUILT_LIBDIR="$(dirname "$BUILT_BIN")"
LD_LIBRARY_PATH="$BUILT_LIBDIR:${LD_LIBRARY_PATH:-}" supports_qwen38 "$BUILT_BIN"
LD_LIBRARY_PATH="$BUILT_LIBDIR:${LD_LIBRARY_PATH:-}" "$BUILT_BIN" --list-devices 2>&1 | grep -q CUDA
REL_BIN="${BUILT_BIN#"$LLAMA_DIR/"}"
if [ -e "$INSTALL_DIR" ]; then
  mv "$INSTALL_DIR" "$INSTALL_DIR.backup.$(date +%Y%m%d%H%M%S).$$"
fi
mv "$LLAMA_DIR" "$INSTALL_DIR"
sudo ln -sf "$INSTALL_DIR/$REL_BIN" /usr/local/bin/llama-server
dirname "$INSTALL_DIR/$REL_BIN" | sudo tee /etc/ld.so.conf.d/llama-cpp.conf >/dev/null
sudo ldconfig
llama-server --version
log_ok "llama.cpp ready: $(command -v llama-server)"
