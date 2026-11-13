#!/usr/bin/env bash
# Stop all stack services (llama-cyberstrike + hexstrike + hexstrike-bridge).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/common.sh"
require_ubuntu_2204
sudo systemctl stop llama-watchdog.timer llama-watchdog.service
sudo systemctl stop llama-cyberstrike
for unit in hexstrike-bridge.service hexstrike.service; do
  if [ "$(systemctl show -p LoadState --value "$unit")" = loaded ]; then
    sudo systemctl stop "$unit"
  fi
done
echo "Stopped."
systemctl --no-pager status llama-cyberstrike hexstrike hexstrike-bridge 2>/dev/null | grep -E '●|Active:' || true
