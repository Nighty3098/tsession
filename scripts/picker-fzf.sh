#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

sq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

LIST_Q="$(sq "$SCRIPT_DIR/list-saved.sh")"
DEL_Q="$(sq "$SCRIPT_DIR/delete-saved.sh")"
KILL_Q="$(sq "$SCRIPT_DIR/kill-live.sh")"
RENAME_Q="$(sq "$SCRIPT_DIR/rename-session.sh")"
CLONE_Q="$(sq "$SCRIPT_DIR/clone-session.sh")"
PREVIEW_Q="$(sq "$SCRIPT_DIR/preview-saved.sh")"

if [ -z "$("$SCRIPT_DIR/list-saved.sh")" ]; then
  tmux display-message "tsession: no saved sessions — hit Prefix + Ctrl-s first" 2>/dev/null \
    || echo "tsession: no saved sessions — hit Prefix + Ctrl-s first"
  exit 0
fi

FZF_ARGS=(
  --delimiter=$'\t' --with-nth=1 --no-multi
  --prompt='session> '
  --header=$'Enter: switch/restore   X: kill live   C: clone\nR: rename to query   D: delete saved   ?: preview   Esc: cancel'
  --bind "D:execute-silent($DEL_Q {2} >/dev/null 2>&1)+reload($LIST_Q)+clear-query"
  --bind "X:execute-silent($KILL_Q {2} >/dev/null 2>&1)+reload($LIST_Q)"
  --bind "C:execute-silent($CLONE_Q {2} {q} >/dev/null 2>&1)+reload($LIST_Q)+clear-query"
  --bind "R:execute-silent($RENAME_Q {2} {q} >/dev/null 2>&1)+reload($LIST_Q)+clear-query"
  --bind "?:toggle-preview"
)
# Preview of windows/panes; off via: set -g @tsession-fzf-preview 'off'
PREVIEW_ON="$(tmux show-option -gqv "@tsession-fzf-preview" 2>/dev/null || echo on)"
if [ "${PREVIEW_ON:-on}" != "off" ]; then
  FZF_ARGS+=(--preview "$PREVIEW_Q {2}" --preview-window='right:55%:wrap:border-left')
fi
[ -n "${TSESSION_FZF_FILTER:-}" ] && FZF_ARGS+=(--filter="$TSESSION_FZF_FILTER")

sel="$("$SCRIPT_DIR/list-saved.sh" | fzf "${FZF_ARGS[@]}")" || sel=""
[ -z "$sel" ] && exit 0

name="${sel##*$'\t'}"
[ -z "$name" ] && exit 0

exec "$SCRIPT_DIR/goto-saved.sh" "$name"
