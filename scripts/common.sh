#!/usr/bin/env bash
# Shared helpers for The Pharaoh Agent V5 installer scripts.
# Sourced by install.sh and every scripts/*.sh — not meant to run standalone.

set -euo pipefail

# --- identity ---------------------------------------------------------------
# When invoked through sudo, keep the real user so files land in THEIR home.
# Run user-owned downloads/configuration as the login user, even with sudo.
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
  exec sudo -H -u "$SUDO_USER" env "PHARAOH_MODEL=${PHARAOH_MODEL:-}" bash "$0" "$@"
fi
STACK_USER="$(id -un)"
STACK_GROUP="$(id -gn 2>/dev/null || id -g)"
STACK_HOME="$(getent passwd "$STACK_USER" 2>/dev/null | cut -d: -f6 || true)"
[ -n "$STACK_HOME" ] || STACK_HOME="$HOME"
export HOME="$STACK_HOME"
export PATH="/usr/local/bin:$STACK_HOME/.local/bin:$STACK_HOME/.opencode/bin:/snap/bin:$PATH"
# Root-only servers need no sudo package.
if [ "$(id -u)" -eq 0 ]; then
  sudo() {
    [ "${1:-}" = -v ] && return 0
    case "${1:-}" in -E|-H) shift ;; esac
    "$@"
  }
fi

MODELS_DIR="$STACK_HOME/models"
LLAMA_DIR="$STACK_HOME/llama.cpp"
HEXSTRIKE_DIR="$STACK_HOME/Hexstrike-AI"
OPENCODE_CONFIG_DIR="$STACK_HOME/.config/opencode"

LLAMA_PORT=8000
HEXSTRIKE_PORT=8888
# Streamable-HTTP MCP bridge (hexstrike-bridge systemd service) — replaces the
# per-session stdio spawn. Long-lived daemon => no poisoned-pipe hangs.
HEXSTRIKE_MCP_BRIDGE_PORT=8890

HF_REPO="huihui-ai/Huihui-Qwen3.8-27B-abliterated-GGUF"
MODEL_FILENAME="Huihui-Qwen3.8-27B-abliterated-Q8_0.gguf"
MODEL_ALIAS="pharaoh-agent"
MODEL_NAME="Qwen3.8-27B Abliterated"
MODEL_HOST=0.0.0.0
MODEL_CONTEXT=131072
case "${PHARAOH_MODEL:-qwen}" in
  qwen) ;;
  cyberstrike)
    HF_REPO="huihui-ai/Huihui-CyberStrike-OffSec-35B-abliterated-GGUF"
    MODEL_FILENAME="Huihui-CyberStrike-OffSec-35B-abliterated-Q8_0.gguf"
    MODEL_ALIAS="pharaoh-review"
    MODEL_NAME="CyberStrike-OffSec-35B Abliterated"
    MODEL_HOST=127.0.0.1
    MODEL_CONTEXT=32768
    LLAMA_PORT=8001
    ;;
  *) printf 'Unknown model: %s\n' "$PHARAOH_MODEL" >&2; exit 2 ;;
esac
MODEL_PATH="$MODELS_DIR/$MODEL_FILENAME"
HEXSTRIKE_REPO="https://github.com/netcuter/Hexstrike-AI.git"

# --- logging ----------------------------------------------------------------
_c_reset=$'\033[0m'; _c_red=$'\033[31m'; _c_grn=$'\033[32m'
_c_yel=$'\033[33m';  _c_blu=$'\033[34m'

log_info()  { printf '%s[INFO]%s  %s\n'  "$_c_blu" "$_c_reset" "$*"; }
log_ok()    { printf '%s[ OK ]%s  %s\n'  "$_c_grn" "$_c_reset" "$*"; }
log_warn()  { printf '%s[WARN]%s  %s\n'  "$_c_yel" "$_c_reset" "$*"; }
log_error() { printf '%s[FAIL]%s  %s\n'  "$_c_red" "$_c_reset" "$*" >&2; }
log_banner() {
  printf '\n%s============================================================%s\n' "$_c_blu" "$_c_reset"
  printf '%s  %s%s\n' "$_c_blu" "$*" "$_c_reset"
  printf '%s============================================================%s\n' "$_c_blu" "$_c_reset"
}

# --- guards -----------------------------------------------------------------
require_ubuntu_2204() {
  if [ "$(uname -s)" != Linux ] || [ ! -r /etc/os-release ]; then
    log_error "Run this installer on Ubuntu 22.04/24.04 Linux with systemd (Windows/Git Bash is unsupported)."
    return 1
  fi
  . /etc/os-release
  if [ "${ID:-}" != ubuntu ] || [[ ! "${VERSION_ID:-}" =~ ^(22.04|24.04)$ ]]; then
    log_error "Supported systems: Ubuntu 22.04/24.04; detected ${PRETTY_NAME:-unknown}."
    return 1
  fi
  [ "$(uname -m)" = x86_64 ] || { log_error "This installer currently requires x86_64."; return 1; }
  [ -d /run/systemd/system ] || { log_error "systemd must be running (enable it first if using WSL)."; return 1; }
}

apt_install() {
  sudo env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 install -y --no-install-recommends "$@"
}

pkg_available() {
  local candidate
  candidate="$(LC_ALL=C apt-cache policy "$1" | sed -n 's/^[[:space:]]*Candidate: //p')"
  [ -n "$candidate" ] && [ "$candidate" != '(none)' ]
}

ensure_python311() {
  if ! command -v python3.11 >/dev/null 2>&1; then
    if ! pkg_available python3.11; then
      sudo add-apt-repository -y ppa:deadsnakes/ppa || return 1
      sudo apt-get update || return 1
    fi
  fi
  apt_install python3.11 python3.11-venv python3.11-dev
}

bootstrap() {
  require_ubuntu_2204 || return 1
  sudo -v || return 1
  sudo apt-get -o DPkg::Lock::Timeout=180 update || return 1
  apt_install ca-certificates curl git jq unzip tar python3 python3-pip python3-venv software-properties-common
}

# Each CLI gets its own environment so incompatible dependency pins cannot
# break other tools or Ubuntu's Python packages.
install_python_cli() {
  local name="$1" spec="$2" venv="/opt/pharaoh-venvs/$1" target entries helper
  helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/python_cli_entries.py"
  sudo mkdir -p /opt/pharaoh-venvs || return 1
  sudo python3 -m venv "$venv" || return 1
  sudo "$venv/bin/python" -m pip install --upgrade pip || return 1
  sudo "$venv/bin/python" -m pip install --upgrade "$spec" || return 1
  sudo "$venv/bin/python" -m pip check || return 1
  entries="$(sudo "$venv/bin/python" "$helper" "$name")" || return 1
  [ -n "$entries" ] || { log_error "No CLI entry points installed for $name"; return 1; }
  while IFS= read -r target; do
    # Keep the HTTPX Python client's entry point away from ProjectDiscovery httpx.
    [ "$target" = httpx ] && continue
    sudo ln -sf "$venv/bin/$target" "/usr/local/bin/$target" || return 1
  done <<<"$entries"
}

ensure_go() {
  local metadata filename checksum tmp
  # Jammy's Go 1.18 cannot bootstrap current tools or automatic toolchains.
  if command -v go >/dev/null 2>&1 && go version | grep -Eq 'go1\.(2[4-9]|[3-9][0-9])\.'; then return 0; fi
  metadata="$(curl -fsSL --retry 3 'https://go.dev/dl/?mode=json')" || return 1
  filename="$(jq -r '[.[0].files[] | select(.os=="linux" and .arch=="amd64" and .kind=="archive")][0].filename' <<<"$metadata")" || return 1
  checksum="$(jq -r '[.[0].files[] | select(.os=="linux" and .arch=="amd64" and .kind=="archive")][0].sha256' <<<"$metadata")" || return 1
  [[ "$filename" =~ ^go[0-9.]+\.linux-amd64\.tar\.gz$ ]] || return 1
  tmp="$(mktemp -d)" || return 1
  curl -fSL --retry 3 "https://go.dev/dl/$filename" -o "$tmp/go.tar.gz" || { rm -rf "$tmp"; return 1; }
  printf '%s  %s\n' "$checksum" "$tmp/go.tar.gz" | sha256sum -c - || { rm -rf "$tmp"; return 1; }
  sudo mkdir -p /usr/local/lib/pharaoh-go || return 1
  sudo tar xzf "$tmp/go.tar.gz" -C /usr/local/lib/pharaoh-go || return 1
  rm -rf "$tmp"
  sudo ln -sf /usr/local/lib/pharaoh-go/go/bin/go /usr/local/bin/go || return 1
  /usr/local/bin/go version
}

# retry <times> <cmd...>
retry() {
  local n=0 max="$1"; shift
  until "$@"; do
    n=$((n + 1))
    if [ "$n" -ge "$max" ]; then
      log_error "Command failed after $max attempts: $*"
      return 1
    fi
    log_warn "Attempt $n/$max failed — retrying in 5s: $*"
    sleep 5
  done
}
