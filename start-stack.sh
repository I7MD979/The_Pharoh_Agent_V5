#!/usr/bin/env bash
# Start all stack services (llama-cyberstrike + hexstrike + hexstrike-bridge).
set -euo pipefail
sudo systemctl start llama-cyberstrike hexstrike hexstrike-bridge
echo "Started. Status:"
systemctl --no-pager --full status llama-cyberstrike hexstrike hexstrike-bridge | grep -E '●|Active:' || true
echo
echo "llama.cpp   : http://localhost:8000/v1/models"
echo "HexStrike   : http://localhost:8888/health"
echo "MCP bridge  : http://127.0.0.1:8890/mcp"
