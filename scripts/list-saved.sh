#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/theme.sh"

US=$'\x1f'

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

SAVE_PATH="${1:-$(get_save_path)}"
[ -f "$SAVE_PATH" ] || exit 0

sessions=()
declare -A win_count
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    \#*|"") continue ;;
    S"$US"*)
      IFS="$US" read -r _ sname _attached <<< "$line"
      [ -z "${sname:-}" ] && continue
      if [ -z "${win_count[$sname]+x}" ]; then
        sessions+=("$sname")
        win_count["$sname"]=0
      fi
      ;;
    W"$US"*)
      IFS="$US" read -r _ ws _widx _wn _wa _wl <<< "$line"
      [ -z "${ws:-}" ] && continue
      if [ -z "${win_count[$ws]+x}" ]; then
        sessions+=("$ws")
        win_count["$ws"]=0
      fi
      win_count["$ws"]=$((win_count["$ws"] + 1))
      ;;
  esac
done < "$SAVE_PATH"

for s in "${sessions[@]}"; do
  nw="${win_count[$s]:-0}"
  if tmux has-session -t "=$s" 2>/dev/null; then
    printf '%s●%s %s (%sw)\t%s\n' "$TS_ANSI_ALIVE" "$TS_RESET" "$s" "$nw" "$s"
  else
    printf '%s○%s %s (%sw)\t%s\n' "$TS_ANSI_SAVED" "$TS_RESET" "$s" "$nw" "$s"
  fi
done
