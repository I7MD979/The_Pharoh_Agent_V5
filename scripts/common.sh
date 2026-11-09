#!/usr/bin/env bash
# Shared helpers for The Pharaoh Agent V5 installer scripts.
# Sourced by install.sh and every scripts/*.sh — not meant to run standalone.

set -euo pipefail

# --- identity ---------------------------------------------------------------
# When invoked through sudo, keep the real user so files land in THEIR home.
STACK_USER="${SUDO_USER:-$(id -un)}"
STACK_HOME="$(getent passwd "$STACK_USER" | cut -d: -f6)"
[ -n "$STACK_HOME" ] || STACK_HOME="$HOME"

MODELS_DIR="$STACK_HOME/models"
LLAMA_DIR="$STACK_HOME/llama.cpp"
HEXSTRIKE_DIR="$STACK_HOME/Hexstrike-AI"
OPENCODE_CONFIG_DIR="$STACK_HOME/.config/opencode"

LLAMA_PORT=8000
HEXSTRIKE_PORT=8888

HF_REPO="huihui-ai/Huihui-Qwen3.8-27B-abliterated-GGUF"
MODEL_FILENAME="Huihui-Qwen3.8-27B-abliterated-Q8_0.gguf"
MODEL_PATH="$MODELS_DIR/$MODEL_FILENAME"
MODEL_ALIAS="pharaoh-agent"
MODEL_NAME="Qwen3.8-27B Abliterated"
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
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    if [ "${ID:-}" != "ubuntu" ] || [ "${VERSION_ID:-}" != "22.04" ]; then
      log_warn "This stack targets Ubuntu 22.04 (detected: ${PRETTY_NAME:-unknown}). Continuing anyway."
    fi
  fi
}

apt_install() {
  DEBIAN_FRONTEND=noninteractive sudo apt-get install -y --no-install-recommends "$@"
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
