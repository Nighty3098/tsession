#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NAME_RAW="${1:-}"
NAME="$(echo "$NAME_RAW" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
[ -z "$NAME" ] && exit 0

sq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

GOTO_Q="$(sq "$SCRIPT_DIR/goto-saved.sh")"
DEL_Q="$(sq "$SCRIPT_DIR/delete-saved.sh")"
KILL_Q="$(sq "$SCRIPT_DIR/kill-live.sh")"
CLONE_Q="$(sq "$SCRIPT_DIR/clone-session.sh")"
RENAME_Q="$(sq "$SCRIPT_DIR/rename-session.sh")"
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
  "Kill live session" "X" "run-shell \"$KILL_Q $NAME_Q; $MENU_Q\"" \
  "Clone as…" "C" "command-prompt -p 'Clone to:' \"run-shell \\\"$CLONE_Q $NAME_Q '%%'; $MENU_Q\\\"\"" \
  "Rename to…" "R" "command-prompt -p 'New name:' \"run-shell \\\"$RENAME_Q $NAME_Q '%%'; $MENU_Q\\\"\"" \
  "" "" "" \
  "Delete saved session" "D" "run-shell \"$DEL_Q $NAME_Q && $MENU_Q\"" \
  "Back to list" "B" "run-shell \"$MENU_Q\""
