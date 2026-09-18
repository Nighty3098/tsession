#!/usr/bin/env bash
# Kill a LIVE session, keeping its snapshot in the save file untouched.
# Usage: kill-live.sh '<name>'

set -euo pipefail

NAME_RAW="${1:-}"
NAME="$(echo "$NAME_RAW" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
[ -z "$NAME" ] && exit 0

say() {
  tmux display-message "tsession: $1" 2>/dev/null || echo "tsession: $1"
}

if ! tmux has-session -t "=$NAME" 2>/dev/null; then
  say "no live session: $NAME"
  exit 1
fi

# If we are attached to the session being killed, move to another one first
# so the client survives.
cur="$(tmux display-message -p '#S' 2>/dev/null || true)"
if [ "$cur" = "$NAME" ]; then
  other="$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -vx "$NAME" | head -n 1 || true)"
  if [ -n "${other:-}" ]; then
    tmux switch-client -t "=$other" 2>/dev/null || true
  fi
fi

tmux kill-session -t "=$NAME" 2>/dev/null || true
say "killed live session '$NAME' (snapshot kept)"
