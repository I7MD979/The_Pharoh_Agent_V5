#!/usr/bin/env bash
set -euo pipefail
export BUNDLE_GEMFILE=/opt/pharaoh-gems/evil-winrm/Gemfile
export BUNDLE_PATH=/opt/pharaoh-gems/evil-winrm/vendor
exec ruby -e 'gem "bundler", "2.4.22"; require "bundler/setup"; load Gem.bin_path("evil-winrm", "evil-winrm")' -- "$@"
