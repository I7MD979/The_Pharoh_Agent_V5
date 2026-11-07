#!/usr/bin/env bash
# Start both stack services (llama-cyberstrike + hexstrike).
set -euo pipefail
sudo systemctl start llama-cyberstrike hexstrike
echo "Started. Status:"
systemctl --no-pager --full status llama-cyberstrike hexstrike | grep -E '●|Active:' || true
echo
echo "llama.cpp : http://localhost:8000/v1/models"
echo "HexStrike : http://localhost:8888/health"
