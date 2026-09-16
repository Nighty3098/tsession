#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NAME_RAW="${1:-}"
NAME="$(echo "$NAME_RAW" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
[ -z "$NAME" ] && exit 0

sq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

GOTO_Q="$(sq "$SCRIPT_DIR/goto-saved.sh")"
DEL_Q="$(sq "$SCRIPT_DIR/delete-saved.sh")"
MENU_Q="$(sq "$SCRIPT_DIR/session-menu.sh")"
NAME_Q="$(sq "$NAME")"

if tmux has-session -t "=$NAME" 2>/dev/null; then
  verb="Switch to"
  state="● alive"
else
  verb="Restore"
  state="○ saved only"
fi

tmux display-menu \
  -T "#[align=centre]$NAME ($state)" -x R -y P \
  "$verb '$NAME'" "S" "run-shell \"$GOTO_Q $NAME_Q\"" \
  "" "" "" \
  "Delete saved session" "D" "run-shell \"$DEL_Q $NAME_Q && $MENU_Q\"" \
  "Back to list" "B" "run-shell \"$MENU_Q\""
