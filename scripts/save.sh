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
TMP="$(mktemp "${SAVE_PATH}.tmp.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

# Scrollback depth per pane (0 = off). Opt-in via:
#   set -g @tsession-history-lines '100'
HISTORY_LINES="$(tmux show-option -gqv "@tsession-history-lines" 2>/dev/null || true)"
case "${HISTORY_LINES:-}" in ''|*[!0-9]*) HISTORY_LINES=0 ;; esac

# Pane environment allowlist, e.g.: set -g @tsession-save-env 'NODE_ENV PYTHONPATH'
# Default (when option is unset/empty): virtualenv/conda essentials + PATH,
# so `source .venv/bin/activate` / `conda activate` survive restore.
# Set to 'off' or 'none' to disable env snapshots entirely.
# Captured per pane from /proc/<pid>/environ (no keystrokes injected)
# plus tmux pane/session/global environments, stored as E records;
# restore re-exports them before re-running commands.
DEFAULT_SAVE_ENV="VIRTUAL_ENV CONDA_PREFIX CONDA_DEFAULT_ENV PATH"
SAVE_ENV_RAW="$(tmux show-option -gqv "@tsession-save-env" 2>/dev/null || true)"
case "$SAVE_ENV_RAW" in off|none|OFF|NONE) SAVE_ENV="" ;; "") SAVE_ENV="$DEFAULT_SAVE_ENV" ;; *) SAVE_ENV="$SAVE_ENV_RAW" ;; esac
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

# All direct children of a pid, one per line.
children_of() {
  ps -o pid= --ppid "$1" 2>/dev/null | tr -s '[:space:]' '\n' | grep -E '^[0-9]+$' || true
}

basename_of_pid() {
  local pid="$1" args base
  args="$(ps -o args= -p "$pid" 2>/dev/null || true)"
  args="$(printf '%s' "$args" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -z "$args" ] && return 1
  base="$(printf '%s' "$args" | awk '{print $1}')"
  base="$(basename "$base" 2>/dev/null || printf '%s' "$base")"
  printf '%s' "${base#-}"
}

is_shell_base() {
  case "$1" in
    sh|bash|dash|zsh|fish|ksh|tcsh|csh) return 0 ;;
    *) return 1 ;;
  esac
}

# Youngest (max pid) child — best guess for foreground when a shell
# has background jobs. Prefers a non-shell child when one exists so a
# `vim + lsp` / `python + bg job` pane is not misclassified as idle.
pick_child() {
  local pid="$1" c best="" best_shell="" base
  for c in $(children_of "$pid"); do
    [ -z "$c" ] && continue
    base="$(basename_of_pid "$c" || true)"
    if [ -n "$base" ] && ! is_shell_base "$base"; then
      if [ -z "$best" ] || [ "$c" -gt "$best" ]; then best="$c"; fi
    else
      if [ -z "$best_shell" ] || [ "$c" -gt "$best_shell" ]; then best_shell="$c"; fi
    fi
  done
  if [ -n "$best" ]; then printf '%s' "$best"; return 0; fi
  [ -n "$best_shell" ] && printf '%s' "$best_shell"
}

full_cmd_of_pane() {
  local pid="$1" child args base
  [ -z "$pid" ] && return 0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    child="$(pick_child "$pid")"
    [ -z "$child" ] && break
    pid="$child"
  done
  args="$(ps -o args= -p "$pid" 2>/dev/null || true)"
  args="$(printf '%s' "$args" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -z "$args" ] && return 0
  base="$(printf '%s' "$args" | awk '{print $1}')"
  base="$(basename "$base" 2>/dev/null || printf '%s' "$base")"
  base="${base#-}"
  case "$base" in
    sh|bash|dash|zsh|fish|ksh|tcsh|csh|tmux|screen)
      # Bare interactive shell (no args) -> nothing to re-run.
      # Shell WITH args (script, -c, ...) is a real program — keep it.
      case "$args" in
        *[\ \	]*) ;; # has args -> keep below
        *) return 0 ;;
      esac
      ;;
  esac
  printf '%s' "$args" | tr "$US" ' '
}

# Deepest foreground process basename of a pane ('' if the pane is gone).
leaf_base_of_pane() {
  local pid="$1" child args base
  [ -z "$pid" ] && return 0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    child="$(pick_child "$pid")"
    [ -z "$child" ] && break
    pid="$child"
  done
  base="$(basename_of_pid "$pid" || true)"
  [ -z "${base:-}" ] && return 0
  printf '%s' "${base#-}"
}

# Read one var from /proc/<pid>/environ (NUL-separated, binary-safe key
# match). NOTE: /proc shows the environ at exec time — a shell's own
# `export`/`source activate` is NOT visible there, but its CHILDREN inherit
# the current env, so read the LEAF (deepest child) first for busy panes.
# Prints value on stdout, returns 0 on hit.
proc_env_of_pid() {
  local pid="$1" name="$2" entry
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -r "/proc/$pid/environ" ] || return 1
  while IFS= read -r -d '' entry || [ -n "${entry:-}" ]; do
    case "$entry" in
      "$name="*) printf '%s' "${entry#*=}"; return 0 ;;
    esac
  done < "/proc/$pid/environ"
  return 1
}

# Deepest descendant pid of a pane (leaf foreground process, or the shell
# itself when idle). Empty when the pane is gone.
deepest_pid_of() {
  local pid="$1" child
  [ -z "$pid" ] && return 1
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    child="$(pick_child "$pid")"
    [ -z "$child" ] && break
    pid="$child"
  done
  printf '%s' "$pid"
}

# All descendant pids of a pane (BFS), youngest/deepest last.
all_descendants_of() {
  local root="$1"
  local queue="$root" next="" pid c depth=0
  while [ "$depth" -lt 10 ] && [ -n "$queue" ]; do
    next=""
    for pid in $queue; do
      for c in $(children_of "$pid"); do
        printf '%s\n' "$c"
        next="$next $c"
      done
    done
    queue="$next"
    depth=$((depth + 1))
  done
}

# Value of $name from /proc: leaf first (freshest inherited env), then
# youngest descendants, then the pane root. Covers busy panes
# (`venv; python server.py`, `sleep`, `nvim`, ...) with zero keystrokes.
proc_env_of_subtree() {
  local pane_pid="$1" name="$2" leaf val c
  [ -n "${pane_pid:-}" ] || return 1
  leaf="$(deepest_pid_of "$pane_pid" || true)"
  if [ -n "${leaf:-}" ] && [ "$leaf" != "$pane_pid" ]; then
    if val="$(proc_env_of_pid "$leaf" "$name")"; then printf '%s' "$val"; return 0; fi
  fi
  for c in $(all_descendants_of "$pane_pid" | tac 2>/dev/null || all_descendants_of "$pane_pid"); do
    if val="$(proc_env_of_pid "$c" "$name")"; then printf '%s' "$val"; return 0; fi
  done
  return 1
}

# Query missing vars from an IDLE shell prompt via a temp file.
# Last resort only: /proc is stale for the shell itself (export/activate
# don't update it) and tmux env doesn't know shell exports.
# Clears the pending input line first (Ctrl-C), so nothing half-typed can
# be executed together with the query. Leading space keeps the query out
# of history when HISTCONTROL=ignorespace/ignoreboth. Always returns 0.
# Supports POSIX shells + fish; other shells return 0 with no output.
query_shell_env() {
  local target="$1" shell="$2" outfile="$3" names="$4" q
  [ -n "$names" ] || return 0
  rm -f "$outfile"
  case "$shell" in
    sh|bash|dash|zsh|ksh)
      q=" { printf '__TSENV_BEGIN__\\n'; for V in $names; do printf '__TSENV_VAR__ %s\\n' \"\$V\"; if printenv \"\$V\" >/dev/null 2>&1; then printenv \"\$V\"; echo '__TSENV_END__'; else echo '__TSENV_UNSET__'; fi; done; echo '__TSENV_DONE__'; } > '$outfile' 2>/dev/null"
      ;;
    fish)
      q="begin; printf '__TSENV_BEGIN__\\n'; for V in $names; printf '__TSENV_VAR__ %s\\n' \$V; printenv \$V; or echo '__TSENV_UNSET__'; echo '__TSENV_END__'; end; echo '__TSENV_DONE__'; end > '$outfile' 2>/dev/null"
      ;;
    *) return 0 ;;
  esac
  tmux send-keys -t "$target" C-c 2>/dev/null || return 0
  tmux send-keys -t "$target" -l "$q" 2>/dev/null || return 0
  tmux send-keys -t "$target" Enter 2>/dev/null || return 0
  for _ in $(seq 1 25); do
    if grep -q '__TSENV_DONE__' "$outfile" 2>/dev/null; then return 0; fi
    sleep 0.1
  done
  return 0
}

# Parse a query outfile, emitting E records for hits. Prints hit names
# (space-separated) on stdout for bookkeeping? No — emits records directly.
emit_query_outfile() {
  local sess="$1" widx="$2" pidx="$3" outfile="$4"
  local line qname="" qval="" qfirst=1 qactive=0 tsprefix='__TSENV_VAR__ '
  grep -q '__TSENV_DONE__' "$outfile" 2>/dev/null || return 0
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
  done < "$outfile"
}

# Value of $name for a pane WITHOUT key injection: /proc subtree (fresh
# inherited env, covers busy panes) then tmux pane/session/global envs.
pane_env_value() {
  local pane_pid="$1" sess="$2" widx="$3" pidx="$4" name="$5"
  local val entry target
  if val="$(proc_env_of_subtree "$pane_pid" "$name")"; then
    printf '%s' "$val"
    return 0
  fi
  target="=$sess:$widx.$pidx"
  entry="$(tmux show-environment -t "$target" "$name" 2>/dev/null \
    || tmux show-environment -t "=$sess" "$name" 2>/dev/null \
    || tmux show-environment -g "$name" 2>/dev/null || true)"
  [ -n "${entry:-}" ] || return 1
  printf '%s' "${entry#*=}"
  return 0
}

# Dump allowlisted environment of one pane (E records):
#  1. /proc subtree + tmux envs (no keystrokes, covers busy panes + fish);
#  2. idle shells where 1. missed vars: ONE injected query for the missing
#     names only (shell exports are invisible in /proc of the shell itself).
dump_pane_env() {
  local sess="$1" widx="$2" pidx="$3" pid="$4"
  local name val leaf target out missing
  [ -n "$SAVE_ENV_CLEAN" ] || return 0
  target="=$sess:$widx.$pidx"
  missing=""
  for name in $SAVE_ENV_CLEAN; do
    if val="$(pane_env_value "$pid" "$sess" "$widx" "$pidx" "$name")"; then
      [ -n "${val:-}" ] || continue
      printf 'E%s%s%s%s%s%s%s%s%s%s%s\n' "$US" "$sess" "$US" "$widx" "$US" "$pidx" "$US" "$(b64 "$name")" "$US" "$(b64 "$val")"
    else
      missing="$missing $name"
    fi
  done
  missing="${missing# }"
  [ -n "${missing:-}" ] || return 0
  leaf="$(leaf_base_of_pane "$pid")"
  case "$leaf" in sh|bash|dash|zsh|ksh|fish) ;; *) return 0 ;; esac
  out="$(mktemp /tmp/tsenv.XXXXXX)"
  if query_shell_env "$target" "$leaf" "$out" "$missing"; then
    emit_query_outfile "$sess" "$widx" "$pidx" "$out"
  fi
  rm -f "$out"
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
