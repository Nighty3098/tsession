#!/usr/bin/env bash

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

get_opt() {
  local opt="$1" default_val="$2"
  local val
  val="$(tmux show-option -gqv "$opt")"
  if [ -z "$val" ]; then
    echo "$default_val"
  else
    echo "$val"
  fi
}

PROMPT_KEY="$(get_opt "@tsession-key" "T")"
MENU_KEY="$(get_opt "@tsession-menu-key" "C-g")"
SAVE_KEY="$(get_opt "@tsession-save-key" "C-s")"
RESTORE_KEY="$(get_opt "@tsession-restore-key" "C-r")"

tmux bind-key "$PROMPT_KEY" command-prompt -p "Session:" -I "#S" "run-shell \"$CURRENT_DIR/scripts/session-handler.sh '%%'\""

tmux bind-key "$MENU_KEY" run-shell "$CURRENT_DIR/scripts/session-picker.sh"

tmux bind-key "$SAVE_KEY" run-shell "$CURRENT_DIR/scripts/save.sh --current"
tmux bind-key "$RESTORE_KEY" run-shell "$CURRENT_DIR/scripts/restore.sh"
