#!/usr/bin/env bash
# Stop all stack services (llama-cyberstrike + hexstrike + hexstrike-bridge).
set -euo pipefail
sudo systemctl stop hexstrike-bridge hexstrike llama-cyberstrike
echo "Stopped."
systemctl --no-pager status llama-cyberstrike hexstrike hexstrike-bridge 2>/dev/null | grep -E '●|Active:' || true
