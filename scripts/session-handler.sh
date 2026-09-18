#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/theme.sh"

SESSION_RAW="${1:-}"

SESSION="$(echo "$SESSION_RAW" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

[ -z "$SESSION" ] && exit 0

SESSION="$(echo "$SESSION" | tr '.:' '__')"

KILL_EXISTING="$(tmux show-option -gqv "@tsession-kill-existing")"
[ -z "$KILL_EXISTING" ] && KILL_EXISTING="off"

session_exists() {
  tmux has-session -t "=$SESSION" 2>/dev/null
}

if session_exists; then
  if [ "$KILL_EXISTING" = "on" ]; then
    tmux kill-session -t "=$SESSION"
    tmux new-session -d -s "$SESSION"
  else
    :
  fi
else
  tmux new-session -d -s "$SESSION"
fi

if [ -n "${TMUX:-}" ]; then
  tmux switch-client -t "=$SESSION" || true
else
  tmux switch-client -t "=$SESSION" 2>/dev/null || tmux attach-session -t "=$SESSION" 2>/dev/null || true
fi

tmux display-message "$TS_TAG → $SESSION" 2>/dev/null || true
