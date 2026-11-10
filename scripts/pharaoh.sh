#!/usr/bin/env bash
# Installed by step 5 with the owning account and CLI path substituted.
set -euo pipefail
STACK_USER='__STACK_USER__'
STACK_HOME='__STACK_HOME__'
OPENCODE_BIN="${PHARAOH_OPENCODE_BIN:-__OPENCODE_BIN__}"

if [ "$(id -u)" -eq 0 ] && [ "$STACK_USER" != root ]; then
  exec sudo -H -u "$STACK_USER" "$0" "$@"
fi
if [ ! -f "$STACK_HOME/.config/opencode/opencode.json" ]; then
  echo "Pharaoh configuration is missing; rerun scripts/05-install-opencode.sh." >&2
  exit 1
fi
if [ ! -x "$OPENCODE_BIN" ]; then
  echo "Configured OpenCode executable is missing: $OPENCODE_BIN. Rerun step 5." >&2
  exit 1
fi
export OPENCODE_CONFIG="$STACK_HOME/.config/opencode/opencode.json"
export XDG_CONFIG_HOME="$STACK_HOME/.config"
# V2's managed service may collide with another user or a stale process. A
# private server avoids that port entirely. V1 does not have this flag.
flags=()
help_text="$("$OPENCODE_BIN" --help 2>&1)"
if grep -q -- '--standalone' <<<"$help_text"; then flags+=(--standalone); fi
exec "$OPENCODE_BIN" "${flags[@]}" --model local/pharaoh-agent "$@"
