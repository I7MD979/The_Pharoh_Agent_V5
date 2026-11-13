#!/usr/bin/env bash
# Start all stack services (llama-cyberstrike + hexstrike + hexstrike-bridge).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/common.sh"
require_ubuntu_2204
if grep -Fq 'Huihui-CyberStrike-OffSec-35B-abliterated-Q8_0.gguf' /etc/systemd/system/llama-cyberstrike.service; then
  sudo systemctl start llama-cyberstrike llama-watchdog.timer
  echo "Local review API: http://127.0.0.1:8001/v1/models"
  exit 0
fi
sudo systemctl start llama-cyberstrike hexstrike hexstrike-bridge
sudo systemctl start llama-watchdog.timer
echo "Started. Status:"
systemctl --no-pager --full status llama-cyberstrike hexstrike hexstrike-bridge | grep -E '●|Active:' || true
echo
echo "llama.cpp   : http://localhost:8000/v1/models"
echo "HexStrike   : http://localhost:8888/health"
echo "MCP bridge  : http://127.0.0.1:8890/mcp"
