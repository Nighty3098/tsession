#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/theme.sh"

sq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

if command -v fzf >/dev/null 2>&1; then
  # @tsession-popup-border 'on' — framed popup with title;
  # anything else (default) — borderless floating panel, colour only in backgrounds.
  BORDER_OPT="$(tmux show-option -gqv "@tsession-popup-border" 2>/dev/null || true)"
  if [ "${BORDER_OPT:-off}" = "on" ]; then
    tmux display-popup -E -w 90% -h 70% -b rounded -s 'bg=black' -S 'fg=default' \
      -T "#[align=centre,$TS_TITLE_BLOCK] Saved sessions #[default]" \
      "$(sq "$SCRIPT_DIR/picker-fzf.sh")"
  else
    tmux display-popup -E -w 90% -h 70% -b none -s 'bg=black' \
      "$(sq "$SCRIPT_DIR/picker-fzf.sh")"
  fi
else
  exec "$SCRIPT_DIR/session-menu.sh"
fi
