#!/usr/bin/env bash
# ============================================================================
# The Pharaoh Agent V5 — master installer
# Target: Ubuntu 22.04, NVIDIA GPU with CUDA (tested: 96 GB RAM / 48 GB VRAM)
# Idempotent: safe to re-run; each step skips work that is already done.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/scripts/common.sh"

require_ubuntu_2204

log_banner "The Pharaoh Agent V5 — local AI pentesting stack installer"
log_info "Repo root : $SCRIPT_DIR"
log_info "User/Home : $STACK_USER / $STACK_HOME"
log_info "GPU check : $(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null || echo 'nvidia-smi NOT FOUND — CUDA required!')"

if ! command -v nvidia-smi >/dev/null 2>&1; then
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
    log_error "Step $n FAILED. Fix the error above and re-run ./install.sh (completed steps are skipped)."
    exit 1
  fi
}

run_step 1 01-install-llamacpp.sh
run_step 2 02-download-model.sh
run_step 3 03-setup-services.sh
run_step 4 04-install-hexstrike.sh
run_step 5 05-install-opencode.sh
run_step 6 06-install-all-tools.sh
run_step 7 07-verify.sh

log_banner "INSTALL COMPLETE"
log_ok "llama.cpp   → http://localhost:8000  (model: $MODEL_ALIAS)"
log_ok "HexStrike   → http://localhost:8888  (MCP bridge: streamable-http on :$HEXSTRIKE_MCP_BRIDGE_PORT)"
log_ok "opencode    → run 'opencode' to start the agent"
log_info "Manage with: ./start-stack.sh / ./stop-stack.sh"
