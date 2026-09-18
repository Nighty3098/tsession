#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/theme.sh"

NAME_RAW="${1:-}"
NAME="$(echo "$NAME_RAW" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
[ -z "$NAME" ] && exit 0

get_save_path() {
  local p
  p="$(tmux show-option -gqv "@tsession-save-path")"
  if [ -z "$p" ]; then
    echo "$HOME/.tmux-tsession.save"
  else
    case "$p" in
      "~"*) echo "$HOME${p#"~"}" ;;
      *) echo "$p" ;;
    esac
  fi
}

switch_to() {
  if [ -n "${TMUX:-}" ]; then
    tmux switch-client -t "=$1" 2>/dev/null || true
  else
    tmux switch-client -t "=$1" 2>/dev/null \
      || tmux attach-session -t "=$1" 2>/dev/null || true
  fi
}

if tmux has-session -t "=$NAME" 2>/dev/null; then
  switch_to "$NAME"
  tmux display-message "$TS_TAG → $NAME" 2>/dev/null || true
  exit 0
fi

exec "$SCRIPT_DIR/restore.sh" "$(get_save_path)" "$NAME"
