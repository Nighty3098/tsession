#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/theme.sh"

US=$'\x1f'

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

SAVE_PATH="${2:-$(get_save_path)}"
if [ ! -f "$SAVE_PATH" ]; then
  tmux display-message "$TS_TAG save file not found" 2>/dev/null || echo "tsession: save file not found"
  exit 1
fi

TMP="$(mktemp "${SAVE_PATH}.tmp.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
removed="$(awk -v US="$US" -v name="$NAME" '
  BEGIN { FS = US; OFS = US; del = 0 }
  /^(S|W|P|H|E)/ && $2 == name { del++; next }
  { print }
  END { print del > "/dev/stderr" }
' "$SAVE_PATH" 2>&1 > "$TMP")"

mv -f "$TMP" "$SAVE_PATH"

if [ "${removed:-0}" -eq 0 ]; then
  tmux display-message "$TS_TAG not in save file: $NAME" 2>/dev/null || echo "tsession: not in save file: $NAME"
  exit 1
fi
tmux display-message "$TS_TAG deleted save of '$NAME' (${removed} lines)" 2>/dev/null \
  || echo "tsession: deleted save of '$NAME' (${removed} lines)"
