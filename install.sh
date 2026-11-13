#!/usr/bin/env bash
# ============================================================================
# The Pharaoh Agent V5 — master installer
# Target: Ubuntu 22.04, NVIDIA GPU with CUDA (tested: 96 GB RAM / 48 GB VRAM)
# Rerun to switch models or resume setup.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/scripts/common.sh"

if [ "${1:-}" = --check ]; then
  require_ubuntu_2204
  nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
  log_ok "Platform and GPU driver checks passed. No packages installed."
  exit 0
fi
if [ "$#" -ne 0 ]; then
  log_error "Usage: ./install.sh [--check]"
  exit 2
fi
require_ubuntu_2204

mkdir -p "$STACK_HOME/.local/share/pharaoh"
exec 9>"$STACK_HOME/.local/share/pharaoh/install.lock"
flock -n 9 || { log_error "Another Pharaoh installation is running."; exit 1; }

installed_unit=/etc/systemd/system/llama-cyberstrike.service
default_model=$INSTALLED_MODEL
if [ -z "${PHARAOH_MODEL:-}" ] && { exec 8<>/dev/tty; } 2>/dev/null; then
  printf '%s\n' '1) Huihui Qwen3.8-27B Q8_0 (OpenCode + MCP tools)' '2) Huihui CyberStrike-OffSec-35B Q8_0 (OpenCode + MCP tools)' '3) Qwen3.5-40B Deckard-Heretic Q8_0 (OpenCode + MCP tools)' >&8
  [ ! -f "$installed_unit" ] || log_info "Applying the selection restarts inference after the model is ready on disk."
  while true; do
    printf 'Choose model [Enter keeps %s]: ' "$default_model" >&8
    read -r choice <&8 || break
    case "$choice" in
      1) PHARAOH_MODEL=qwen; break ;;
      2) PHARAOH_MODEL=cyberstrike; break ;;
      3) PHARAOH_MODEL=deckard; break ;;
      '') break ;;
    esac
  done
  exec 8>&-
fi
export PHARAOH_MODEL="${PHARAOH_MODEL:-$default_model}"

log_banner "The Pharaoh Agent V5 — installer"
log_info "Repo root : $SCRIPT_DIR"
log_info "User/Home : $STACK_USER / $STACK_HOME"
log_info "GPU check : $(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null || echo 'nvidia-smi NOT FOUND — CUDA required!')"

if ! nvidia-smi --query-gpu=name --format=csv,noheader >/dev/null 2>&1; then
  log_error "nvidia-smi not found. Install NVIDIA drivers + CUDA before continuing."
  exit 1
fi

run_step() {
  local n="$1"; shift
  local script="$SCRIPT_DIR/scripts/$1"
  log_banner "Step $n — $script"
  if bash "$script"; then
    log_ok "Step $n finished."
  else
    log_error "Step $n failed. Fix the error above and rerun ./install.sh."
    exit 1
  fi
}

if [ -f "$installed_unit" ] && command -v llama-server >/dev/null; then
  sudo -v
  run_step 2 02-download-model.sh
  run_step 3 03-setup-services.sh
  # Resume only when the agent is already wired to the selected model; a model
  # switch has to regenerate the OpenCode profile and MCP registration.
  if [ -f /etc/systemd/system/hexstrike-bridge.service ] && command -v pharaoh >/dev/null &&
     [ -f "$OPENCODE_CONFIG_DIR/opencode.json" ] &&
     grep -Fq "local/$MODEL_ALIAS" "$OPENCODE_CONFIG_DIR/opencode.json" &&
     grep -Fq "127.0.0.1:$LLAMA_PORT/v1" "$OPENCODE_CONFIG_DIR/opencode.json"; then
    exit 0
  fi
else
  bootstrap
  run_step 1 01-install-llamacpp.sh
  run_step 2 02-download-model.sh
  run_step 3 03-setup-services.sh
fi

run_step 4 04-install-hexstrike.sh
run_step 5 05-install-opencode.sh
run_step 6 06-install-all-tools.sh
run_step 7 07-verify.sh

log_banner "INSTALL COMPLETE"
log_ok "llama.cpp   → http://localhost:$LLAMA_PORT  (model: $MODEL_ALIAS)"
log_ok "HexStrike   → http://localhost:8888  (MCP bridge: streamable-http on :$HEXSTRIKE_MCP_BRIDGE_PORT)"
log_ok "opencode    → run 'pharaoh' to start the agent with $MODEL_ALIAS and HexStrike tools"
log_info "Manage with: ./start-stack.sh / ./stop-stack.sh"
