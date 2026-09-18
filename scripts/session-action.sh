#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/theme.sh"

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
  state="#[fg=$CURRENT,bold]● alive"
else
  verb="Restore"
  state="#[fg=$TS_FG,dim]○ saved only"
fi

tmux display-menu \
  -T "#[align=centre,$TS_TITLE_BLOCK] $NAME #[default]$state#[default]" -x R -y P \
  "#[fg=$CURRENT,bold]$verb '$NAME'#[default]" "S" "run-shell \"$GOTO_Q $NAME_Q\"" \
  "#[fg=$ACCENT,bold]Kill live session#[default]" "X" "run-shell \"$KILL_Q $NAME_Q; $MENU_Q\"" \
  "Clone as…" "C" "command-prompt -p 'Clone to:' \"run-shell \\\"$CLONE_Q $NAME_Q '%%'; $MENU_Q\\\"\"" \
  "Rename to…" "R" "command-prompt -p 'New name:' \"run-shell \\\"$RENAME_Q $NAME_Q '%%'; $MENU_Q\\\"\"" \
  "" "" "" \
  "#[fg=$ACCENT]Delete saved session#[default]" "D" "run-shell \"$DEL_Q $NAME_Q && $MENU_Q\"" \
  "Back to list" "B" "run-shell \"$MENU_Q\""
