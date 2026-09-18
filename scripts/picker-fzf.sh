#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/theme.sh"

sq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

LIST_Q="$(sq "$SCRIPT_DIR/list-saved.sh")"
DEL_Q="$(sq "$SCRIPT_DIR/delete-saved.sh")"
KILL_Q="$(sq "$SCRIPT_DIR/kill-live.sh")"
RENAME_Q="$(sq "$SCRIPT_DIR/rename-session.sh")"
CLONE_Q="$(sq "$SCRIPT_DIR/clone-session.sh")"
PREVIEW_Q="$(sq "$SCRIPT_DIR/preview-saved.sh")"

if [ -z "$("$SCRIPT_DIR/list-saved.sh")" ]; then
  tmux display-message "$TS_TAG no saved sessions — hit Prefix + Ctrl-s first" 2>/dev/null \
    || echo "tsession: no saved sessions — hit Prefix + Ctrl-s first"
  exit 0
fi

FZF_ARGS=(
  --delimiter=$'\t' --with-nth=1 --no-multi --ansi
  --highlight-line
  --color "$TS_FZF_MAIN"
  --color "$TS_FZF_INFO"
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
# Borderless popup (@tsession-popup-border != 'on'): no tmux frame, so fake
# the edge with an invisible surface-coloured fzf border + padding.
# Both are painted (opaque) — unlike --margin, which stays transparent.
BORDER_OPT="$(tmux show-option -gqv "@tsession-popup-border" 2>/dev/null || true)"
if [ "${BORDER_OPT:-off}" != "on" ]; then
  FZF_ARGS+=(--border=rounded --padding=0,1 --color "$TS_FZF_BORDER")
else
  FZF_ARGS+=(--border=none)
fi
[ -n "${TSESSION_FZF_FILTER:-}" ] && FZF_ARGS+=(--filter="$TSESSION_FZF_FILTER")

# fzf wraps every frame in DEC2026 sync markers; tmux before 3.8 tears
# such frames inside popup overlays (slices of panes underneath flash
# through). Strip the markers via a pty relay (default on;
# set -g @tsession-fzf-nosync 'off' for bare fzf).
NOSYNC_OPT="$(tmux show-option -gqv "@tsession-fzf-nosync" 2>/dev/null || true)"
FZF_BIN=(fzf)
if [ "${NOSYNC_OPT:-on}" != "off" ] \
    && command -v python3 >/dev/null 2>&1 \
    && [ -x "$SCRIPT_DIR/fzf-nosync.py" ]; then
  FZF_BIN=("$SCRIPT_DIR/fzf-nosync.py" fzf)
fi

sel="$("$SCRIPT_DIR/list-saved.sh" | "${FZF_BIN[@]}" "${FZF_ARGS[@]}")" || sel=""
[ -z "$sel" ] && exit 0

name="${sel##*$'\t'}"
[ -z "$name" ] && exit 0

exec "$SCRIPT_DIR/goto-saved.sh" "$name"
