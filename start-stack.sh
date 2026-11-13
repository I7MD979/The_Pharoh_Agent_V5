#!/usr/bin/env bash
# Start all stack services (llama-cyberstrike + hexstrike + hexstrike-bridge).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/common.sh"
require_ubuntu_2204
sudo systemctl start llama-cyberstrike
# The API and bridge are installed by step 4 for both models. Tolerate an
# existing model-only installation that predates them.
for unit in hexstrike.service hexstrike-bridge.service; do
  if [ "$(systemctl show -p LoadState --value "$unit" 2>/dev/null)" = loaded ]; then
    sudo systemctl start "$unit"
  fi
done
sudo systemctl start llama-watchdog.timer
echo "Started. Status:"
systemctl --no-pager --full status llama-cyberstrike hexstrike hexstrike-bridge 2>/dev/null | grep -E '●|Active:' || true
echo
echo "llama.cpp   : http://localhost:$LLAMA_PORT/v1/models"
echo "HexStrike   : http://localhost:$HEXSTRIKE_PORT/health"
echo "MCP bridge  : http://127.0.0.1:$HEXSTRIKE_MCP_BRIDGE_PORT/mcp"
