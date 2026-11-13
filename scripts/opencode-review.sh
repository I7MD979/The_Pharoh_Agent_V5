#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
opencode_bin="$(command -v opencode)" || {
  echo "OpenCode is required to open the review session." >&2
  exit 1
}
help_text="$("$opencode_bin" --help 2>&1)"
if ! grep -q -- '--standalone' <<<"$help_text"; then
  echo "This launcher requires OpenCode 2.2.7 or newer with --standalone." >&2
  exit 1
fi

curl -fsS --max-time 5 http://127.0.0.1:8001/v1/models |
  python3 -c 'import json, sys; sys.exit(not any(m["id"] == "pharaoh-review" for m in json.load(sys.stdin)["data"]))' || {
    echo "Start pharaoh-review on port 8001 before opening OpenCode." >&2
    exit 1
  }

session_dir="$(mktemp -d /tmp/pharaoh-review.XXXXXXXX)"
trap 'rm -rf -- "$session_dir"' EXIT
export XDG_CONFIG_HOME="$session_dir/config"
export XDG_DATA_HOME="$session_dir/data"
export XDG_STATE_HOME="$session_dir/state"
export XDG_CACHE_HOME="$session_dir/cache"
unset OPENCODE_CONFIG OPENCODE_CONFIG_DIR OPENCODE_CONFIG_CONTENT
mkdir -p "$XDG_CONFIG_HOME/opencode" "$session_dir/work"
cp "$repo_root/config/opencode-review.json" "$XDG_CONFIG_HOME/opencode/opencode.json"
cd "$session_dir/work"
"$opencode_bin" --standalone --model pharaoh-local/pharaoh-review
