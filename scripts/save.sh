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

# Pane environment allowlist, e.g.: set -g @tsession-save-env 'NODE_ENV PYTHONPATH'
# (empty = off). Captured per pane from the live shell (idle shell prompts
# only) plus tmux pane/session/global environments, stored as E records;
# restore re-exports them before re-running commands.
SAVE_ENV="$(tmux show-option -gqv "@tsession-save-env" 2>/dev/null || true)"
SAVE_ENV_CLEAN=""
for _n in $SAVE_ENV; do
  _c="$(printf '%s' "$_n" | tr -cd 'A-Za-z0-9_')"
  case "$_c" in ""|[0-9]*) continue ;; esac
  case " $SAVE_ENV_CLEAN " in *" $_c "*) continue ;; esac
  SAVE_ENV_CLEAN="$SAVE_ENV_CLEAN $_c"
done
SAVE_ENV_CLEAN="${SAVE_ENV_CLEAN# }"
unset _n _c

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

# Deepest foreground process basename of a pane ('' if the pane is gone).
leaf_base_of_pane() {
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
  printf '%s' "${base#-}"
}

# Query allowlisted vars from an idle shell prompt via a temp file.
# Only for POSIX-ish shells; never touches panes running other programs.
# Clears the pending input line first (Ctrl-C), so nothing half-typed can
# be executed together with the query. Always returns 0.
query_shell_env() {
  local target="$1" shell="$2" outfile="$3" names="$4" i
  case "$shell" in sh|bash|dash|zsh|ksh) ;; *) return 0 ;; esac
  [ -n "$names" ] || return 0
  rm -f "$outfile"
  tmux send-keys -t "$target" C-c 2>/dev/null || return 0
  tmux send-keys -t "$target" -l " { printf '__TSENV_BEGIN__\\n'; for V in $names; do printf '__TSENV_VAR__ %s\\n' \"\$V\"; if printenv \"\$V\" >/dev/null 2>&1; then printenv \"\$V\"; echo '__TSENV_END__'; else echo '__TSENV_UNSET__'; fi; done; echo '__TSENV_DONE__'; } > '$outfile' 2>/dev/null" 2>/dev/null || return 0
  tmux send-keys -t "$target" Enter 2>/dev/null || return 0
  for i in $(seq 1 25); do
    if grep -q '__TSENV_DONE__' "$outfile" 2>/dev/null; then return 0; fi
    sleep 0.1
  done
  return 0
}

# Dump allowlisted environment of one pane (E records): live shell query
# first, then tmux pane/session/global environments for the rest.
dump_pane_env() {
  local sess="$1" widx="$2" pidx="$3" pid="$4" target
  local leaf entry name val found out qname qval qfirst qactive line tsprefix
  [ -n "$SAVE_ENV_CLEAN" ] || return 0
  target="=$sess:$widx.$pidx"
  found=" "
  leaf="$(leaf_base_of_pane "$pid")"
  case "$leaf" in sh|bash|dash|zsh|ksh)
    out="/tmp/tsenv-$$-$pid"
    if query_shell_env "$target" "$leaf" "$out" "$SAVE_ENV_CLEAN"; then
      if grep -q '__TSENV_DONE__' "$out" 2>/dev/null; then
        qname=""; qval=""; qfirst=1; qactive=0
        tsprefix='__TSENV_VAR__ '
        while IFS= read -r line || [ -n "${line:-}" ]; do
          case "$line" in
            __TSENV_BEGIN__) qactive=1; continue ;;
            __TSENV_DONE__) break ;;
          esac
          [ "$qactive" = "1" ] || continue
          case "$line" in
            "$tsprefix"*)
              qname="${line#$tsprefix}"; qval=""; qfirst=1; continue ;;
            __TSENV_END__)
              if [ -n "$qname" ]; then
                printf 'E%s%s%s%s%s%s%s%s%s%s%s\n' "$US" "$sess" "$US" "$widx" "$US" "$pidx" "$US" "$(b64 "$qname")" "$US" "$(b64 "$qval")"
                found="$found$qname "
              fi
              qname=""; continue ;;
            __TSENV_UNSET__) qname=""; continue ;;
            *)
              if [ -n "$qname" ]; then
                if [ "$qfirst" = "1" ]; then qval="$line"; qfirst=0; else qval="$qval
$line"; fi
              fi
              ;;
          esac
        done < "$out"
      fi
    fi
    rm -f "$out"
    ;;
  esac
  for name in $SAVE_ENV_CLEAN; do
    case "$found" in *" $name "*) continue ;; esac
    entry="$(tmux show-environment -t "$target" "$name" 2>/dev/null \
      || tmux show-environment -t "=$sess" "$name" 2>/dev/null \
      || tmux show-environment -g "$name" 2>/dev/null || true)"
    [ -n "$entry" ] || continue
    val="${entry#*=}"
    printf 'E%s%s%s%s%s%s%s%s%s%s%s\n' "$US" "$sess" "$US" "$widx" "$US" "$pidx" "$US" "$(b64 "$name")" "$US" "$(b64 "$val")"
  done
  return 0
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
    dump_pane_env "$sess" "$widx" "$pidx" "$pid"
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
    echo "# tsession save v2 $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    dump_block
  } > "$TMP"
  [ -f "$SAVE_PATH" ] && cp -f "$SAVE_PATH" "$SAVE_PATH.bak" 2>/dev/null || true
  mv -f "$TMP" "$SAVE_PATH"
  count_s="$(grep -c "^S$US" "$SAVE_PATH" || true)"
  count_w="$(grep -c "^W$US" "$SAVE_PATH" || true)"
  count_p="$(grep -c "^P$US" "$SAVE_PATH" || true)"
  count_h="$(grep -c "^H$US" "$SAVE_PATH" || true)"
  count_e="$(grep -c "^E$US" "$SAVE_PATH" || true)"
  msg="saved ${count_s} sessions, ${count_w} windows, ${count_p} panes → $SAVE_PATH"
  [ "$count_h" -gt 0 ] && msg="$msg (+${count_h} history)"
  [ "$count_e" -gt 0 ] && msg="$msg (+${count_e} env)"
  say "$msg"
else
  {
    echo "# tsession save v2 $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [ -f "$SAVE_PATH" ]; then
      awk -v US="$US" -v name="$ONLY" '
        BEGIN { FS = US; OFS = US }
        /^#/ { next }
        /^(S|W|P|H|E)/ && $2 == name { next }
        { print }
      ' "$SAVE_PATH" || true
    fi
    dump_block
  } > "$TMP"
  [ -f "$SAVE_PATH" ] && cp -f "$SAVE_PATH" "$SAVE_PATH.bak" 2>/dev/null || true
  mv -f "$TMP" "$SAVE_PATH"
  count_w="$(awk -v US="$US" -v name="$ONLY" 'BEGIN{FS=US} /^W/ && $2==name{c++} END{print c+0}' "$SAVE_PATH")"
  count_p="$(awk -v US="$US" -v name="$ONLY" 'BEGIN{FS=US} /^P/ && $2==name{c++} END{print c+0}' "$SAVE_PATH")"
  count_e="$(awk -v US="$US" -v name="$ONLY" 'BEGIN{FS=US} /^E/ && $2==name{c++} END{print c+0}' "$SAVE_PATH")"
  msg="saved session '$ONLY' (${count_w} windows, ${count_p} panes"
  [ "$count_e" -gt 0 ] && msg="$msg, ${count_e} env"
  say "$msg) → $SAVE_PATH"
fi
