#!/usr/bin/env bash
# Stop all stack services (llama-cyberstrike + hexstrike + hexstrike-bridge).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/common.sh"
require_ubuntu_2204
sudo systemctl stop llama-watchdog.timer llama-watchdog.service
sudo systemctl stop hexstrike-bridge hexstrike llama-cyberstrike
echo "Stopped."
systemctl --no-pager status llama-cyberstrike hexstrike hexstrike-bridge 2>/dev/null | grep -E '●|Active:' || true
