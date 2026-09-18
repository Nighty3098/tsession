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

say() {
  tmux display-message "$TS_TAG$1" 2>/dev/null || echo "tsession: $1"
}

SAVE_PATH=""
ONLY=""
if [ "${1:-}" = "--current" ]; then
  ONLY="--current"
  SAVE_PATH="${2:-}"
else
  SAVE_PATH="${1:-}"
  ONLY="${2:-}"
fi
[ -z "$SAVE_PATH" ] && SAVE_PATH="$(get_save_path)"

if [ "$ONLY" = "--current" ]; then
  ONLY="$(tmux display-message -p '#S' 2>/dev/null || true)"
  if [ -z "$ONLY" ]; then
    say "no current session (run from inside tmux)"
    exit 1
  fi
fi

mkdir -p "$(dirname "$SAVE_PATH")"
TMP="$SAVE_PATH.tmp.$$"

# Scrollback depth per pane (0 = off). Opt-in via:
#   set -g @tsession-history-lines '100'
HISTORY_LINES="$(tmux show-option -gqv "@tsession-history-lines" 2>/dev/null || true)"
case "${HISTORY_LINES:-}" in ''|*[!0-9]*) HISTORY_LINES=0 ;; esac

b64() { printf '%s' "$1" | base64 -w0 2>/dev/null || printf '%s' "$1" | base64 | tr -d '\n'; }

full_cmd_of_pane() {
  local pid="$1" child args base
  [ -z "$pid" ] && return 0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    child="$(ps -o pid= --ppid "$pid" 2>/dev/null | head -n 1 | tr -d '[:space:]')"
    [ -z "$child" ] && break
    pid="$child"
  done
  args="$(ps -o args= -p "$pid" 2>/dev/null || true)"
  args="$(echo "$args" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -z "$args" ] && return 0
  base="$(echo "$args" | awk '{print $1}')"
  base="$(basename "$base" 2>/dev/null || echo "$base")"
  base="${base#-}"
  case "$base" in
    sh|bash|dash|zsh|fish|ksh|tcsh|csh|tmux|screen) return 0 ;;
  esac
  printf '%s' "$args" | tr "$US" ' '
}

dump_block() {
  local win_src pane_src
  if [ -n "$ONLY" ]; then
    if ! tmux has-session -t "=$ONLY" 2>/dev/null; then
      say "no such live session: $ONLY"
      exit 1
    fi
    local attached
    attached="$(tmux display-message -p -t "=$ONLY" '#{?session_attached,1,0}' 2>/dev/null || echo 0)"
    printf 'S%s%s%s%s\n' "$US" "$ONLY" "$US" "$attached"
    win_src="$(tmux list-windows -t "=$ONLY" -F "W${US}#{session_name}${US}#{window_index}${US}#{window_name}${US}#{window_active}${US}#{window_layout}" 2>/dev/null || true)"
    pane_src="$(tmux list-panes -t "=$ONLY" -F "P${US}#{session_name}${US}#{window_index}${US}#{pane_index}${US}#{pane_active}${US}#{pane_current_path}${US}#{pane_pid}${US}#{pane_current_command}" 2>/dev/null || true)"
  else
    tmux list-sessions -F "S${US}#{session_name}${US}#{?session_attached,1,0}" 2>/dev/null || true
    win_src="$(tmux list-windows -a -F "W${US}#{session_name}${US}#{window_index}${US}#{window_name}${US}#{window_active}${US}#{window_layout}" 2>/dev/null || true)"
    pane_src="$(tmux list-panes -a -F "P${US}#{session_name}${US}#{window_index}${US}#{pane_index}${US}#{pane_active}${US}#{pane_current_path}${US}#{pane_pid}${US}#{pane_current_command}" 2>/dev/null || true)"
  fi

  while IFS="$US" read -r _ sess widx wname wactive wlayout; do
    [ -z "${sess:-}" ] && continue
    printf 'W%s%s%s%s%s%s%s%s%s%s%s\n' "$US" "$sess" "$US" "$widx" "$US" "$(b64 "$wname")" "$US" "$wactive" "$US" "$wlayout"
  done <<< "$win_src"

  while IFS="$US" read -r _ sess widx pidx pactive cwd pid _cur; do
    [ -z "${sess:-}" ] && continue
    cmd="$(full_cmd_of_pane "$pid")"
    printf 'P%s%s%s%s%s%s%s%s%s%s%s%s%s\n' "$US" "$sess" "$US" "$widx" "$US" "$pidx" "$US" "$pactive" "$US" "$(b64 "$cwd")" "$US" "$(b64 "$cmd")"
    if [ "$HISTORY_LINES" -gt 0 ]; then
      hist="$(tmux capture-pane -p -J -S "-$HISTORY_LINES" -t "=$sess:$widx.$pidx" 2>/dev/null || true)"
      if [ -n "$hist" ]; then
        # Guard against pathological panes (huge scrollback dumps).
        if [ "${#hist}" -gt 102400 ]; then
          hist="$(printf '%s' "$hist" | tail -c 102400 || true)"
        fi
        printf 'H%s%s%s%s%s%s%s%s%s\n' "$US" "$sess" "$US" "$widx" "$US" "$pidx" "$US" "$(b64 "$hist")"
      fi
    fi
  done <<< "$pane_src"
}

if [ -z "$ONLY" ]; then
  {
    echo "# tsession save v1 $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    dump_block
  } > "$TMP"
  mv -f "$TMP" "$SAVE_PATH"
  count_s="$(grep -c "^S$US" "$SAVE_PATH" || true)"
  count_w="$(grep -c "^W$US" "$SAVE_PATH" || true)"
  count_p="$(grep -c "^P$US" "$SAVE_PATH" || true)"
  count_h="$(grep -c "^H$US" "$SAVE_PATH" || true)"
  msg="saved ${count_s} sessions, ${count_w} windows, ${count_p} panes → $SAVE_PATH"
  [ "$count_h" -gt 0 ] && msg="$msg (+${count_h} history)"
  say "$msg"
else
  {
    echo "# tsession save v1 $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [ -f "$SAVE_PATH" ]; then
      awk -v US="$US" -v name="$ONLY" '
        BEGIN { FS = US; OFS = US }
        /^#/ { next }
        /^(S|W|P)/ && $2 == name { next }
        { print }
      ' "$SAVE_PATH" || true
    fi
    dump_block
  } > "$TMP"
  mv -f "$TMP" "$SAVE_PATH"
  count_w="$(awk -v US="$US" -v name="$ONLY" 'BEGIN{FS=US} /^W/ && $2==name{c++} END{print c+0}' "$SAVE_PATH")"
  count_p="$(awk -v US="$US" -v name="$ONLY" 'BEGIN{FS=US} /^P/ && $2==name{c++} END{print c+0}' "$SAVE_PATH")"
  say "saved session '$ONLY' (${count_w} windows, ${count_p} panes) → $SAVE_PATH"
fi
