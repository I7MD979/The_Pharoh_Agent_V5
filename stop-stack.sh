#!/usr/bin/env bash
# Stop both stack services (llama-cyberstrike + hexstrike).
set -euo pipefail
sudo systemctl stop hexstrike llama-cyberstrike
echo "Stopped."
systemctl --no-pager status llama-cyberstrike hexstrike 2>/dev/null | grep -E '●|Active:' || true
