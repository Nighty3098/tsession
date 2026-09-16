#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

sq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

LIST_Q="$(sq "$SCRIPT_DIR/list-saved.sh")"
DEL_Q="$(sq "$SCRIPT_DIR/delete-saved.sh")"
GOTO_Q="$(sq "$SCRIPT_DIR/goto-saved.sh")"

if [ -z "$("$SCRIPT_DIR/list-saved.sh")" ]; then
  tmux display-message "tsession: no saved sessions — hit Prefix + Ctrl-s first" 2>/dev/null \
    || echo "tsession: no saved sessions — hit Prefix + Ctrl-s first"
  exit 0
fi

FZF_ARGS=(
  --delimiter=$'\t' --with-nth=1 --no-multi
  --prompt='session> '
  --header='Enter: switch/restore   D: delete saved   Esc: cancel'
  --bind "D:execute-silent($DEL_Q {2} >/dev/null 2>&1)+reload($LIST_Q)+clear-query"
)
[ -n "${TSESSION_FZF_FILTER:-}" ] && FZF_ARGS+=(--filter="$TSESSION_FZF_FILTER")

sel="$("$SCRIPT_DIR/list-saved.sh" | fzf "${FZF_ARGS[@]}")" || sel=""
[ -z "$sel" ] && exit 0

name="${sel##*$'\t'}"
[ -z "$name" ] && exit 0

exec "$SCRIPT_DIR/goto-saved.sh" "$name"
