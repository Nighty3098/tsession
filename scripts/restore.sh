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
  printf '%s' "$1" | base64 -d 2>/dev/null || printf '%s' "$1" | base64 -D 2>/dev/null || printf ''
}

is_shell_basename() {
  case "$1" in
    sh|bash|dash|zsh|fish|ksh|tcsh|csh|tmux|screen|"") return 0 ;;
    *) return 1 ;;
  esac
}

# Collapse a saved command to one safe line: ps output may contain
# newlines/CRs, and send-keys -l would execute each line separately.
sanitize_cmd() {
  printf '%s' "$1" | tr '\n\r' '  ' | tr "$US" ' ' \
    | sed 's/[[:space:]][[:space:]]*/ /g;s/^[[:space:]]*//;s/[[:space:]]*$//'
}

# True if the program of a saved command line exists on this machine.
cmd_available() {
  local first="${1%% *}" base
  [ -z "$first" ] && return 1
  if [[ "$first" == */* ]]; then
    [ -x "$first" ] && return 0 || return 1
  fi
  base="$(basename "$first")"
  command -v "$base" >/dev/null 2>&1
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

# Wait until the pane runs an interactive shell (fresh panes need a moment).
wait_for_shell() {
  local target="$1" i cmd
  for i in $(seq 1 30); do
    cmd="$(tmux display-message -p -t "$target" '#{pane_current_command}' 2>/dev/null || true)"
    case "$cmd" in
      sh|bash|dash|zsh|fish|ksh|tcsh|csh|"") return 0 ;;
    esac
    sleep 0.1
  done
  return 1
}

sessions_ordered=()
attached_session=""
declare -A seen_session

TMPDIR_WORK="$(mktemp -d)"
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

wins_of() { grep "^W$US$1$US" "$WINLIST" || true; }
panes_of() { grep "^P$US$1$US$2$US" "$PANELIST" || true; }
env_in_win() { grep "^E$US$1$US$2$US" "$ENVLIST" || true; }

TOTAL_CMDS_RUN=0; TOTAL_CMDS_SKIPPED=0; TOTAL_HIST=0; TOTAL_ENV=0

for s in "${sessions_ordered[@]}"; do
  first_win=1
  while IFS= read -r wline || [ -n "${wline:-}" ]; do
    [ -z "${wline:-}" ] && continue
    IFS="$US" read -r _ _ws widx wname_b64 wactive wlayout <<< "$wline"
    wname="$(b64d "$wname_b64")"
    [ -z "$wname" ] && wname="main"

    first_cwd=""
    first_cmd=""
    while IFS= read -r pline || [ -n "${pline:-}" ]; do
      [ -z "${pline:-}" ] && continue
      IFS="$US" read -r _ _ps _pw _pidx _pactive cwd_b64 cmd_b64 <<< "$pline"
      first_cwd="$(b64d "$cwd_b64")"
      first_cmd="$(b64d "$cmd_b64")"
      break
    done < <(panes_of "$s" "$widx")

    [ -n "$first_cwd" ] && [ -d "$first_cwd" ] || first_cwd="$HOME"

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

    mapfile -t plines < <(panes_of "$s" "$widx")
    [ "${#plines[@]}" -le 1 ] && continue

    first_p=1
    for pline in "${plines[@]}"; do
      if [ "$first_p" -eq 1 ]; then first_p=0; continue; fi
      IFS="$US" read -r _ _ps _pw _pidx _pactive cwd_b64 _cmd_b64 <<< "$pline"
      pcwd="$(b64d "$cwd_b64")"
      [ -n "$pcwd" ] && [ -d "$pcwd" ] || pcwd="$HOME"
      tmux split-window -d -t "=$s:$widx" -c "$pcwd" 2>/dev/null || \
        tmux split-window -d -h -t "=$s:$widx" -c "$pcwd" 2>/dev/null || true
    done
    if [ -n "${wlayout:-}" ]; then
      tmux select-layout -t "=$s:$widx" "$wlayout" 2>/dev/null || true
    fi
  done < <(wins_of "$s")

  # Replay saved pane environment (allowlist) before history/commands, so
  # re-run commands inherit it. E records are grouped by pane; live panes
  # are paired by ORDER within the window (same as commands below).
  while IFS= read -r wline || [ -n "${wline:-}" ]; do
    [ -z "${wline:-}" ] && continue
    IFS="$US" read -r _ es ewidx _ewn _ewa _ewl <<< "$wline"
    mapfile -t saved_e < <(env_in_win "$s" "$ewidx")
    [ "${#saved_e[@]}" -eq 0 ] && continue
    mapfile -t live_ep < <(live_panes_of "$s" "$ewidx")
    cur_epidx=""; pi=-1
    for eline in "${saved_e[@]}"; do
      [ -z "${eline:-}" ] && continue
      IFS="$US" read -r _ _fs _fw epidx ename_b64 eval_b64 <<< "$eline"
      if [ "$epidx" != "$cur_epidx" ]; then cur_epidx="$epidx"; pi=$((pi + 1)); fi
      lp="${live_ep[$pi]:-}"
      [ -z "$lp" ] && continue
      ename="$(b64d "$ename_b64")"
      evalue="$(b64d "$eval_b64")"
      case "$ename" in ""|*[!A-Za-z0-9_]*|[0-9]*) continue ;; esac
      target="=$es:$ewidx.$lp"
      pane_exists "$target" || continue
      wait_for_shell "$target" || true
      tmux set-environment -t "$target" "$ename" "$evalue" 2>/dev/null || true
      tmux send-keys -t "$target" -l "export $ename=\"\$(echo '$eval_b64' | base64 -d 2>/dev/null || echo '$eval_b64' | base64 -D)\"" 2>/dev/null || continue
      tmux send-keys -t "$target" Enter 2>/dev/null || true
      TOTAL_ENV=$((TOTAL_ENV + 1))
    done
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
      mapfile -t saved_h < <(grep "^H$US$s$US$hwidx$US" "$HISTLIST" || true)
      [ "${#saved_h[@]}" -eq 0 ] && continue
      mapfile -t live_hp < <(live_panes_of "$s" "$hwidx")
      hi=0
      for hline in "${saved_h[@]}"; do
        [ -z "${hline:-}" ] && { hi=$((hi + 1)); continue; }
        IFS="$US" read -r _ hs hw hp hcontent <<< "$hline"
        htext="$(b64d "$hcontent")"
        hi=$((hi + 1))
        [ -z "$htext" ] && continue
        lp="${live_hp[$((hi - 1))]:-}"
        [ -z "$lp" ] && continue
        safe_s="$(printf '%s' "$hs" | tr -c 'A-Za-z0-9_-' '_')"
        hfile="$HISTCACHE/${safe_s}_${hw}_${hp}.txt"
        printf '%s\n' "$htext" > "$hfile" 2>/dev/null || continue
        target="=$hs:$hw.$lp"
        pane_exists "$target" || continue
        wait_for_shell "$target" || true
        tmux send-keys -t "$target" -l "cat '$hfile'" 2>/dev/null || continue
        tmux send-keys -t "$target" Enter 2>/dev/null || continue
        hist_replayed=$((hist_replayed + 1))
      done
    done < <(wins_of "$s")
  fi

  # Saved panes are paired with live panes by ORDER within the window (see above).
  cmds_run=0; cmds_skipped=0
  while IFS= read -r wline || [ -n "${wline:-}" ]; do
    [ -z "${wline:-}" ] && continue
    IFS="$US" read -r _ _cs cwidx _cwn _cwa _cwl <<< "$wline"
    mapfile -t saved_p < <(panes_of "$s" "$cwidx")
    [ "${#saved_p[@]}" -eq 0 ] && continue
    mapfile -t live_cp < <(live_panes_of "$s" "$cwidx")
    pi=0
    for pline in "${saved_p[@]}"; do
      [ -z "${pline:-}" ] && { pi=$((pi + 1)); continue; }
      IFS="$US" read -r _ ps pw pidx pactive cwd_b64 cmd_b64 <<< "$pline"
      pcwd="$(b64d "$cwd_b64")"
      pcmd="$(b64d "$cmd_b64")"
      lp="${live_cp[$pi]:-}"
      pi=$((pi + 1))
      [ -z "$pcmd" ] && continue
      [ -z "$lp" ] && { cmds_skipped=$((cmds_skipped + 1)); continue; }
      [ "$RESTORE_CMDS" = "on" ] || { cmds_skipped=$((cmds_skipped + 1)); continue; }
      pcmd="$(sanitize_cmd "$pcmd")"
      [ -z "$pcmd" ] && continue
      target="=$ps:$pw.$lp"
      pane_exists "$target" || { cmds_skipped=$((cmds_skipped + 1)); continue; }
      base="$(echo "$pcmd" | awk '{print $1}')"
      base="$(basename "$base" 2>/dev/null || echo "$base")"
      is_shell_basename "$base" && continue
      if ! cmd_available "$pcmd"; then
        cmds_skipped=$((cmds_skipped + 1))
        continue
      fi
      wait_for_shell "$target" || true
      tmux send-keys -t "$target" -l "$pcmd" 2>/dev/null || continue
      tmux send-keys -t "$target" Enter 2>/dev/null || continue
      cmds_run=$((cmds_run + 1))
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
  while IFS= read -r pline || [ -n "${pline:-}" ]; do
    [ -z "${pline:-}" ] && continue
    IFS="$US" read -r _ ps pw pidx pactive _cwd_b64 _cmd_b64 <<< "$pline"
    if [ "$pactive" = "1" ]; then
      tmux select-pane -t "=$ps:$pw.$pidx" 2>/dev/null || true
    fi
  done < <(grep "^P$US$s$US" "$PANELIST" || true)
done

rm -rf "$TMPDIR_WORK"

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
tmux display-message "$TS_TAG $msg" 2>/dev/null \
  || echo "tsession: $msg"
