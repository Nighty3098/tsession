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

sq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

SAVE_PATH="$(get_save_path)"
if [ ! -f "$SAVE_PATH" ]; then
  tmux display-message "$TS_TAG no save file yet — hit Prefix + Ctrl-s first" 2>/dev/null \
    || echo "tsession: no save file yet — hit Prefix + Ctrl-s first"
  exit 0
fi

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

if [ "${#sessions[@]}" -eq 0 ]; then
  tmux display-message "$TS_TAG save file is empty" 2>/dev/null || echo "tsession: save file is empty"
  exit 0
fi

ACTION_Q="$(sq "$SCRIPT_DIR/session-action.sh")"
CMD=(tmux display-menu -T "#[align=centre,$TS_TITLE_BLOCK] Saved sessions #[default] (Enter = actions)" -x R -y P)
KEYS="0123456789abcdefghijklmnopqrstuvwxyz"
ki=0
for s in "${sessions[@]}"; do
  nw="${win_count[$s]:-0}"
  if tmux has-session -t "=$s" 2>/dev/null; then
    label="#[fg=$CURRENT,bold]●#[default] $s (${nw}w)"
  else
    label="#[fg=$TS_FG,dim]○#[default] $s (${nw}w)"
  fi
  if [ "$ki" -lt "${#KEYS}" ]; then
    key="${KEYS:$ki:1}"
    ki=$((ki + 1))
  else
    key=""
  fi
  CMD+=("$label" "$key" "run-shell \"$ACTION_Q $(sq "$s")\"")
done

SAVE_Q="$(sq "$SCRIPT_DIR/save.sh")"
RESTORE_Q="$(sq "$SCRIPT_DIR/restore.sh")"
HANDLER_Q="$(sq "$SCRIPT_DIR/session-handler.sh")"
CMD+=(
  "" "" ""
  "#[bg=$ACCENT,fg=$ACCENT_FG,bold] Save all #[default]" "S" "run-shell \"$SAVE_Q\""
  "#[bg=$CURRENT,fg=$CURRENT_FG,bold] Restore all #[default]" "R" "run-shell \"$RESTORE_Q\""
  "#[bg=$MATCH,fg=$MATCH_FG,bold] New session… #[default]" "N" "command-prompt -p Session: -I '#S' \"run-shell \\\"$HANDLER_Q '%%'\\\"\""
)

"${CMD[@]}"
