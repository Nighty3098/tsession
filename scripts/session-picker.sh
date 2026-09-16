#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

sq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

if command -v fzf >/dev/null 2>&1; then
  tmux display-popup -E -w 70% -h 60% -T "Saved sessions" "$(sq "$SCRIPT_DIR/picker-fzf.sh")"
else
  exec "$SCRIPT_DIR/session-menu.sh"
fi
