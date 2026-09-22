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
ONLY="${2:-}"

# Re-running saved commands: 'on' (default) or 'off' (restore shells only).
#   set -g @tsession-restore-cmds 'off'
RESTORE_CMDS="$(tmux show-option -gqv "@tsession-restore-cmds" 2>/dev/null || true)"
[ -z "$RESTORE_CMDS" ] && RESTORE_CMDS="on"

# Re-printing captured scrollback (H lines): 'on' (default) or 'off'.
#   set -g @tsession-restore-history 'off'
RESTORE_HIST="$(tmux show-option -gqv "@tsession-restore-history" 2>/dev/null || true)"
[ -z "$RESTORE_HIST" ] && RESTORE_HIST="on"
if [ ! -f "$SAVE_PATH" ]; then
  tmux display-message "$TS_TAG save file not found: $SAVE_PATH" 2>/dev/null || echo "tsession: save file not found: $SAVE_PATH"
  exit 1
fi

b64d() {
  if [ -z "${1:-}" ]; then printf ''; return 0; fi
  case "$1" in *[!A-Za-z0-9+/=]*) printf ''; return 1 ;; esac
  printf '%s' "$1" | base64 -d 2>/dev/null || printf '%s' "$1" | base64 -D 2>/dev/null || { printf ''; return 1; }
}

# b64 charset check for values embedded into `echo '...' | base64 -d`.
# Without this a crafted save file could break out of single quotes.
is_b64() {
  case "${1:-}" in ""|*[!A-Za-z0-9+/=]*) return 1 ;; *) return 0 ;; esac
}

is_shell_basename() {
  case "$1" in
    sh|bash|dash|zsh|fish|ksh|tcsh|csh|tmux|screen|"") return 0 ;;
    *) return 1 ;;
  esac
}

# Bare interactive shell (no args) -> nothing to re-run.
# Shell WITH args (script, -c, ...) is a real program -> keep it.
is_bare_shell_cmd() {
  local cmd="$1" first rest base
  first="${cmd%%[[:space:]]*}"
  [ "$first" = "$cmd" ] && rest="" || rest="${cmd#*[[:space:]]}"
  base="$(basename "$first" 2>/dev/null || printf '%s' "$first")"
  base="${base#-}"
  is_shell_basename "$base" || return 1
  # `bash`, `zsh -i`, `bash -l` -> bare; `bash script.sh`, `bash -c ...` -> keep
  case "$cmd" in
    *[\ \	]*) ;;
    *) return 0 ;;
  esac
  case "$rest" in ""|-l|-i|-s|-c|-lc|-ic) return 0 ;; -*) return 0 ;; esac
  return 1
}

# Shell-quote a string for single-quoted use: ' -> '\''
shquote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# Collapse a saved command to one safe line: ps output may contain
# newlines/CRs, and send-keys -l would execute each line separately.
sanitize_cmd() {
  printf '%s' "$1" | tr '\n\r' '  ' | tr "$US" ' ' \
    | sed 's/[[:space:]][[:space:]]*/ /g;s/^[[:space:]]*//;s/[[:space:]]*$//'
}

# True if the program of a saved command line exists on this machine.
# Strips wrappers (sudo/doas/env assignments/nohup/timeout/nice) so
# `sudo docker ...`, `VAR=x cmd`, `env FOO=bar cmd` resolve to `cmd`.
# Shell builtins (cd/export/...) count as available — they need no binary.
cmd_available() {
  local cmd="$1" first rest tok
  cmd="$(printf '%s' "$cmd" | sed 's/^[[:space:]]*//')"
  [ -z "$cmd" ] && return 1
  rest="$cmd"
  while :; do
    first="${rest%%[[:space:]]*}"
    case "$first" in
      sudo|doas|nohup|timeout|nice|stdbuf|unbuffer|setsid|chrt|ionice|taskset|numactl)
        rest="${rest#*[[:space:]]}"; rest="$(printf '%s' "$rest" | sed 's/^[[:space:]]*//')"
        case "$first" in sudo|doas|timeout|nice|stdbuf|ionice|taskset|numactl|chrt)
          # skip wrapper flags: -u user, -n, --...=..., -<letters>
          while :; do
            tok="${rest%%[[:space:]]*}"
            case "$tok" in
              -*) rest="${rest#*[[:space:]]}"; rest="$(printf '%s' "$rest" | sed 's/^[[:space:]]*//')"
                  case "$tok" in -u|--user|-g|--group|-C|--config|-p|--priority|-a|--affinity) rest="${rest#*[[:space:]]}"; rest="$(printf '%s' "$rest" | sed 's/^[[:space:]]*//')" ;; esac
                  [ -z "$rest" ] && return 1
                  ;;
              *) break ;;
            esac
          done
          ;;
        esac
        [ -z "$rest" ] && return 1
        continue
        ;;
      env|command)
        rest="${rest#*[[:space:]]}"; rest="$(printf '%s' "$rest" | sed 's/^[[:space:]]*//')"
        [ -z "$rest" ] && return 1
        continue
        ;;
      *=*) # VAR=val assignment prefix
        case "$first" in [A-Za-z_]*=*) rest="${rest#*[[:space:]]}"; rest="$(printf '%s' "$rest" | sed 's/^[[:space:]]*//')"; [ -z "$rest" ] && return 1; continue ;; esac
        break
        ;;
      *) break ;;
    esac
  done
  first="${rest%%[[:space:]]*}"
  [ -z "$first" ] && return 1
  case "$first" in
    cd|echo|export|source|alias|exec|eval|set|unset|true|false|:|test|\[|if|then|else|fi|for|while|do|done|function|return|exit|logout|history|jobs|fg|bg|wait|kill|trap|umask|ulimit|shopt|complete|bind|builtin|caller|declare|typeset|local|readonly|shift|getopts|pwd|dirs|pushd|popd)
      return 0 ;;
  esac
  if [[ "$first" == */* ]]; then
    [ -x "$first" ] && return 0 || return 1
  fi
  command -v "$(basename "$first")" >/dev/null 2>&1
}

# True if the exact pane target exists (has-session is session-level and
# can't be trusted with window.pane targets across tmux versions).
pane_exists() {
  tmux display-message -p -t "$1" '#{pane_id}' >/dev/null 2>&1
}

# Live pane indexes of a window, one per line, in creation order.
live_panes_of() {
  tmux list-panes -t "=$1:$2" -F '#{pane_index}' 2>/dev/null || true
}

# Wait until the pane runs an interactive shell (fresh panes need a moment),
# then let the prompt settle so stacked send-keys (export/cd/cmd) don't
# interleave. Returns 1 on timeout, caller decides (with `|| true`).
wait_for_shell() {
  local target="$1" i cmd
  for i in $(seq 1 30); do
    cmd="$(tmux display-message -p -t "$target" '#{pane_current_command}' 2>/dev/null || true)"
    case "$cmd" in
      sh|bash|dash|zsh|fish|ksh|tcsh|csh|"") sleep 0.2; return 0 ;;
    esac
    sleep 0.1
  done
  return 1
}

# Short pause after each send-keys Enter so the shell consumes export/cd
# before the next line is typed.
settle() { sleep 0.15; }

sessions_ordered=()
attached_session=""
declare -A seen_session

TMPDIR_WORK="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_WORK"' EXIT
WINLIST="$TMPDIR_WORK/win"
PANELIST="$TMPDIR_WORK/pane"
HISTLIST="$TMPDIR_WORK/hist"
ENVLIST="$TMPDIR_WORK/env"
: > "$WINLIST"; : > "$PANELIST"; : > "$HISTLIST"; : > "$ENVLIST"

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    \#*|"") continue ;;
    S"$US"*)
      IFS="$US" read -r _ sname sattached <<< "$line"
      [ -z "${sname:-}" ] && continue
      if [ -z "${seen_session[$sname]:-}" ]; then
        seen_session["$sname"]=1
        sessions_ordered+=("$sname")
        if [ "${sattached:-0}" = "1" ] && [ -z "$attached_session" ]; then
          attached_session="$sname"
        fi
      fi
      ;;
    W"$US"*) printf '%s\n' "$line" >> "$WINLIST" ;;
    P"$US"*) printf '%s\n' "$line" >> "$PANELIST" ;;
    H"$US"*) printf '%s\n' "$line" >> "$HISTLIST" ;;
    E"$US"*) printf '%s\n' "$line" >> "$ENVLIST" ;;
  esac
done < "$SAVE_PATH"

[ "${#sessions_ordered[@]}" -eq 0 ] && { echo "tsession: empty save file"; exit 1; }

if [ -n "$ONLY" ]; then
  found=0
  for s in "${sessions_ordered[@]}"; do
    if [ "$s" = "$ONLY" ]; then found=1; break; fi
  done
  if [ "$found" -eq 0 ]; then
    tmux display-message "$TS_TAG session not in save file: $ONLY" 2>/dev/null \
      || echo "tsession: session not in save file: $ONLY"
    exit 1
  fi
  sessions_ordered=("$ONLY")
  attached_session="$ONLY"
fi

for s in "${sessions_ordered[@]}"; do
  if tmux has-session -t "=$s" 2>/dev/null; then
    tmux kill-session -t "=$s" 2>/dev/null || true
  fi
done

wins_of() { grep -F "W${US}$1${US}" "$WINLIST" || true; }
panes_of() { grep -F "P${US}$1${US}$2${US}" "$PANELIST" || true; }
env_in_win() { grep -F "E${US}$1${US}$2${US}" "$ENVLIST" || true; }
hist_in_win() { grep -F "H${US}$1${US}$2${US}" "$HISTLIST" || true; }

# Saved panes of a window sorted by saved pane_index (numeric field 4).
# Guarantees deterministic saved->live ORDER mapping regardless of
# list-panes order in the save file.
sorted_panes_of() {
  panes_of "$1" "$2" | sort -t "$US" -k4,4n || true
}

TOTAL_CMDS_RUN=0; TOTAL_CMDS_SKIPPED=0; TOTAL_HIST=0; TOTAL_ENV=0
MISSING_DIRS=0

for s in "${sessions_ordered[@]}"; do
  first_win=1
  while IFS= read -r wline || [ -n "${wline:-}" ]; do
    [ -z "${wline:-}" ] && continue
    IFS="$US" read -r _ _ws widx wname_b64 wactive wlayout <<< "$wline"
    wname="$(b64d "$wname_b64" || true)"
    [ -z "$wname" ] && wname="main"

    first_cwd=""
    first_cmd=""
    while IFS= read -r pline || [ -n "${pline:-}" ]; do
      [ -z "${pline:-}" ] && continue
      IFS="$US" read -r _ _ps _pw _pidx _pactive cwd_b64 cmd_b64 <<< "$pline"
      first_cwd="$(b64d "$cwd_b64" || true)"
      first_cmd="$(b64d "$cmd_b64" || true)"
      break
    done < <(sorted_panes_of "$s" "$widx")

    if [ -n "$first_cwd" ] && [ -d "$first_cwd" ]; then
      :
    else
      [ -n "$first_cwd" ] && MISSING_DIRS=$((MISSING_DIRS + 1))
      first_cwd="$HOME"
    fi

    if [ "$first_win" -eq 1 ]; then
      tmux new-session -d -s "$s" -n "$wname" -c "$first_cwd" -x 200 -y 50 2>/dev/null \
        || tmux new-session -d -s "$s" -n "$wname" -c "$first_cwd" 2>/dev/null \
        || tmux new-session -d -s "$s" -n "$wname" 2>/dev/null
      cur_idx="$(tmux display-message -p -t "=$s:" '#{window_index}' 2>/dev/null || echo "")"
      if [ -n "$cur_idx" ] && [ "$cur_idx" != "$widx" ]; then
        tmux move-window -s "=$s:$cur_idx" -t "=$s:$widx" 2>/dev/null || true
      fi
      first_win=0
    else
      if ! tmux new-window -d -t "=$s:$widx" -n "$wname" -c "$first_cwd" 2>/dev/null; then
        new_id="$(tmux new-window -d -P -F '#{window_index}' -t "=$s:" -n "$wname" -c "$first_cwd" 2>/dev/null || true)"
        if [ -n "$new_id" ] && [ "$new_id" != "$widx" ]; then
          tmux move-window -s "=$s:$new_id" -t "=$s:$widx" 2>/dev/null || true
        fi
      fi
    fi
    tmux rename-window -t "=$s:$widx" "$wname" 2>/dev/null || true
  done < <(wins_of "$s")

  while IFS= read -r wline || [ -n "${wline:-}" ]; do
    [ -z "${wline:-}" ] && continue
    IFS="$US" read -r _ _ws widx _wname_b64 _wactive wlayout <<< "$wline"

    mapfile -t plines < <(sorted_panes_of "$s" "$widx")
    [ "${#plines[@]}" -le 1 ] && continue

    first_p=1
    for pline in "${plines[@]}"; do
      if [ "$first_p" -eq 1 ]; then first_p=0; continue; fi
      IFS="$US" read -r _ _ps _pw _pidx _pactive cwd_b64 _cmd_b64 <<< "$pline"
      pcwd="$(b64d "$cwd_b64" || true)"
      if [ -n "$pcwd" ] && [ -d "$pcwd" ]; then
        :
      else
        [ -n "$pcwd" ] && MISSING_DIRS=$((MISSING_DIRS + 1))
        pcwd="$HOME"
      fi
      tmux split-window -d -t "=$s:$widx" -c "$pcwd" 2>/dev/null || \
        tmux split-window -d -h -t "=$s:$widx" -c "$pcwd" 2>/dev/null || true
    done
    if [ -n "${wlayout:-}" ]; then
      tmux select-layout -t "=$s:$widx" "$wlayout" 2>/dev/null || true
    fi
  done < <(wins_of "$s")

  # Replay saved pane environment (allowlist) before history/commands, so
  # re-run commands inherit it. Saved panes are sorted by pane_index and
  # paired with live panes by ORDER (creation order == sorted saved order),
  # so replay works when pane-base-index differs from the save-time server.
  while IFS= read -r wline || [ -n "${wline:-}" ]; do
    [ -z "${wline:-}" ] && continue
    IFS="$US" read -r _ es ewidx _ewn _ewa _ewl <<< "$wline"
    mapfile -t saved_e < <(env_in_win "$s" "$ewidx" | sort -t "$US" -k4,4n || true)
    [ "${#saved_e[@]}" -eq 0 ] && continue
    mapfile -t live_ep < <(live_panes_of "$s" "$ewidx")
    cur_epidx=""; pi=-1
    # Batch all exports of one live pane into a single send-keys line:
    # one prompt roundtrip per pane instead of per variable.
    batch_target=""; batch_cmds=""; batch_n=0
    flush_env_batch() {
      [ -n "$batch_target" ] && [ -n "$batch_cmds" ] || return 0
      pane_exists "$batch_target" || { batch_target=""; batch_cmds=""; return 0; }
      wait_for_shell "$batch_target" || true
      tmux send-keys -t "$batch_target" -l "$batch_cmds" 2>/dev/null || { batch_target=""; batch_cmds=""; return 0; }
      tmux send-keys -t "$batch_target" Enter 2>/dev/null || true
      settle
      batch_target=""; batch_cmds=""
    }
    for eline in "${saved_e[@]}"; do
      [ -z "${eline:-}" ] && continue
      IFS="$US" read -r _ _fs _fw epidx ename_b64 eval_b64 <<< "$eline"
      if [ "$epidx" != "$cur_epidx" ]; then cur_epidx="$epidx"; pi=$((pi + 1)); fi
      lp="${live_ep[$pi]:-}"
      [ -z "$lp" ] && continue
      is_b64 "$ename_b64" || continue
      is_b64 "$eval_b64" || continue
      ename="$(b64d "$ename_b64" || true)"
      evalue="$(b64d "$eval_b64" || true)"
      case "$ename" in ""|*[!A-Za-z0-9_]*|[0-9]*) continue ;; esac
      [ -n "${evalue:-}" ] || continue
      target="=$es:$ewidx.$lp"
      pane_exists "$target" || continue
      # Session env for future panes + batched explicit export below.
      # eval_b64 is base64-alphabet only (checked above), so embedding it
      # in single quotes is safe; decoded bytes are never re-parsed.
      tmux set-environment -t "=$es" "$ename" "$evalue" 2>/dev/null || true
      if [ "$target" != "$batch_target" ] && [ -n "$batch_target" ]; then
        flush_env_batch
        TOTAL_ENV=$((TOTAL_ENV + batch_n))
        batch_n=0
      fi
      batch_target="$target"
      if [ -n "$batch_cmds" ]; then batch_cmds="$batch_cmds; "; fi
      batch_cmds="${batch_cmds}export $ename=\"\$(echo '$eval_b64' | base64 -d 2>/dev/null || echo '$eval_b64' | base64 -D)\""
      batch_n=$((batch_n + 1))
    done
    if [ -n "$batch_target" ]; then
      batch_n="${batch_n:-0}"
      flush_env_batch
      TOTAL_ENV=$((TOTAL_ENV + batch_n))
    fi
    unset -f flush_env_batch
    unset batch_target batch_cmds batch_n
  done < <(wins_of "$s")

  # Re-print captured scrollback (approximation: the text is catted into the
  # fresh pane so it is visible again; exact scrollback state can't be set
  # via tmux API). Files live in a persistent cache dir — NOT in TMPDIR_WORK —
  # because the shell executes `cat` asynchronously after send-keys returns.
  # Saved panes are paired with live panes by ORDER within the window, so
  # replay also works when pane-base-index differs from the save-time server.
  hist_replayed=0
  if [ "$RESTORE_HIST" = "on" ]; then
    HISTCACHE="$HOME/.cache/tsession/pane-history"
    mkdir -p "$HISTCACHE" 2>/dev/null || true
    while IFS= read -r wline || [ -n "${wline:-}" ]; do
      [ -z "${wline:-}" ] && continue
      IFS="$US" read -r _ _hs hwidx _wn _wa _wl <<< "$wline"
      mapfile -t saved_h < <(hist_in_win "$s" "$hwidx" | sort -t "$US" -k4,4n || true)
      [ "${#saved_h[@]}" -eq 0 ] && continue
      mapfile -t live_hp < <(live_panes_of "$s" "$hwidx")
      hi=0
      for hline in "${saved_h[@]}"; do
        [ -z "${hline:-}" ] && { hi=$((hi + 1)); continue; }
        IFS="$US" read -r _ hs hw hp hcontent <<< "$hline"
        is_b64 "$hcontent" || { hi=$((hi + 1)); continue; }
        htext="$(b64d "$hcontent" || true)"
        hi=$((hi + 1))
        [ -z "$htext" ] && continue
        lp="${live_hp[$((hi - 1))]:-}"
        [ -z "$lp" ] && continue
        safe_s="$(printf '%s' "$hs" | tr -c 'A-Za-z0-9_-' '_')"
        case "$hw" in ''|*[!0-9]*) continue ;; esac
        case "$hp" in ''|*[!0-9]*) continue ;; esac
        hfile="$HISTCACHE/${safe_s}_${hw}_${hp}.txt"
        printf '%s\n' "$htext" > "$hfile" 2>/dev/null || continue
        target="=$hs:$hw.$lp"
        pane_exists "$target" || continue
        wait_for_shell "$target" || true
        tmux send-keys -t "$target" -l "cat $(shquote "$hfile")" 2>/dev/null || continue
        tmux send-keys -t "$target" Enter 2>/dev/null || continue
        settle
        hist_replayed=$((hist_replayed + 1))
      done
    done < <(wins_of "$s")
  fi

  # Saved panes (sorted by pane_index) are paired with live panes by ORDER
  # within the window (creation order == sorted saved order).
  cmds_run=0; cmds_skipped=0
  while IFS= read -r wline || [ -n "${wline:-}" ]; do
    [ -z "${wline:-}" ] && continue
    IFS="$US" read -r _ _cs cwidx _cwn _cwa _cwl <<< "$wline"
    mapfile -t saved_p < <(sorted_panes_of "$s" "$cwidx")
    [ "${#saved_p[@]}" -eq 0 ] && continue
    mapfile -t live_cp < <(live_panes_of "$s" "$cwidx")
    pi=0
    for pline in "${saved_p[@]}"; do
      [ -z "${pline:-}" ] && { pi=$((pi + 1)); continue; }
      IFS="$US" read -r _ ps pw pidx pactive cwd_b64 cmd_b64 <<< "$pline"
      pcwd="$(b64d "$cwd_b64" || true)"
      pcmd="$(b64d "$cmd_b64" || true)"
      lp="${live_cp[$pi]:-}"
      pi=$((pi + 1))
      [ -z "$lp" ] && { cmds_skipped=$((cmds_skipped + 1)); continue; }
      target="=$ps:$pw.$lp"
      pane_exists "$target" || { cmds_skipped=$((cmds_skipped + 1)); continue; }
      # Guarantee the saved working dir no matter what: panes are created
      # with -c, but a shell rc may cd elsewhere on startup (an idle shell
      # with no command would otherwise stay there, e.g. in $HOME).
      want_cd="$HOME"
      [ -n "$pcwd" ] && [ -d "$pcwd" ] && want_cd="$pcwd"
      # Decide whether there is a runnable command for this pane.
      runcmd=""
      if [ -n "$pcmd" ]; then
        if [ "$RESTORE_CMDS" != "on" ]; then
          cmds_skipped=$((cmds_skipped + 1))
        else
          pcmd="$(sanitize_cmd "$pcmd")"
          if [ -z "$pcmd" ]; then
            :
          elif is_bare_shell_cmd "$pcmd"; then
            :
          elif ! cmd_available "$pcmd"; then
            cmds_skipped=$((cmds_skipped + 1))
          else
            runcmd="$pcmd"
          fi
        fi
      fi
      wait_for_shell "$target" || true
      if [ -n "$runcmd" ]; then
        # Combined into ONE line so export/cd/cmd can't interleave.
        tmux send-keys -t "$target" -l "cd $(shquote "$want_cd") && $runcmd" 2>/dev/null || continue
      else
        tmux send-keys -t "$target" -l "cd $(shquote "$want_cd")" 2>/dev/null || continue
      fi
      tmux send-keys -t "$target" Enter 2>/dev/null || continue
      settle
      [ -n "$runcmd" ] && cmds_run=$((cmds_run + 1))
    done
  done < <(wins_of "$s")
  TOTAL_CMDS_RUN=$((TOTAL_CMDS_RUN + cmds_run))
  TOTAL_CMDS_SKIPPED=$((TOTAL_CMDS_SKIPPED + cmds_skipped))
  TOTAL_HIST=$((TOTAL_HIST + hist_replayed))

  while IFS= read -r wline || [ -n "${wline:-}" ]; do
    [ -z "${wline:-}" ] && continue
    IFS="$US" read -r _ _ws widx _wname_b64 wactive _wlayout <<< "$wline"
    if [ "$wactive" = "1" ]; then
      tmux select-window -t "=$s:$widx" 2>/dev/null || true
    fi
  done < <(wins_of "$s")
  # Active pane: map saved pane_index -> live pane_index by ORDER
  # (sorted saved order == creation order). The old code used the saved
  # $pidx directly and broke with a different pane-base-index or gaps.
  while IFS= read -r wline || [ -n "${wline:-}" ]; do
    [ -z "${wline:-}" ] && continue
    IFS="$US" read -r _ _as awidx _awn _awa _awl <<< "$wline"
    mapfile -t _saved_ap < <(sorted_panes_of "$s" "$awidx")
    [ "${#_saved_ap[@]}" -eq 0 ] && continue
    mapfile -t _live_ap < <(live_panes_of "$s" "$awidx")
    _ai=0
    for _apline in "${_saved_ap[@]}"; do
      [ -z "${_apline:-}" ] && { _ai=$((_ai + 1)); continue; }
      IFS="$US" read -r _ _aps _apw _apidx _apactive _acwd _acmd <<< "$_apline"
      _lp="${_live_ap[$_ai]:-}"
      _ai=$((_ai + 1))
      if [ "${_apactive:-}" = "1" ] && [ -n "$_lp" ]; then
        tmux select-pane -t "=$s:$awidx.$_lp" 2>/dev/null || true
        break
      fi
    done
    unset _saved_ap _live_ap _ai _apline _aps _apw _apidx _apactive _acwd _acmd _lp
  done < <(wins_of "$s")
done



if [ -n "$attached_session" ]; then
  if [ -n "${TMUX:-}" ]; then
    tmux switch-client -t "=$attached_session" 2>/dev/null || true
  else
    tmux switch-client -t "=$attached_session" 2>/dev/null \
      || tmux attach-session -t "=$attached_session" 2>/dev/null || true
  fi
fi

msg="restored ${#sessions_ordered[@]} sessions from $SAVE_PATH (${TOTAL_CMDS_RUN} cmds, ${TOTAL_CMDS_SKIPPED} skipped, ${TOTAL_HIST} history"
[ "$TOTAL_ENV" -gt 0 ] && msg="$msg, ${TOTAL_ENV} env"
msg="$msg)"
[ "$MISSING_DIRS" -gt 0 ] && msg="$msg [${MISSING_DIRS} dirs missing → \$HOME]"
tmux display-message "$TS_TAG $msg" 2>/dev/null \
  || echo "tsession: $msg"
