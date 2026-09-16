#!/usr/bin/env bash

set -euo pipefail

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
if [ ! -f "$SAVE_PATH" ]; then
  tmux display-message "tsession: save file not found: $SAVE_PATH" 2>/dev/null || echo "tsession: save file not found: $SAVE_PATH"
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

sessions_ordered=()
attached_session=""
declare -A seen_session

TMPDIR_WORK="$(mktemp -d)"
WINLIST="$TMPDIR_WORK/win"
PANELIST="$TMPDIR_WORK/pane"
: > "$WINLIST"; : > "$PANELIST"

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
  esac
done < "$SAVE_PATH"

[ "${#sessions_ordered[@]}" -eq 0 ] && { echo "tsession: empty save file"; exit 1; }

if [ -n "$ONLY" ]; then
  found=0
  for s in "${sessions_ordered[@]}"; do
    if [ "$s" = "$ONLY" ]; then found=1; break; fi
  done
  if [ "$found" -eq 0 ]; then
    tmux display-message "tsession: session not in save file: $ONLY" 2>/dev/null \
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

  while IFS= read -r pline || [ -n "${pline:-}" ]; do
    [ -z "${pline:-}" ] && continue
    IFS="$US" read -r _ ps pw pidx pactive cwd_b64 cmd_b64 <<< "$pline"
    pcwd="$(b64d "$cwd_b64")"
    pcmd="$(b64d "$cmd_b64")"
    target="=$ps:$pw.$pidx"
    tmux has-session -t "$target" 2>/dev/null || continue
    if [ -n "$pcmd" ]; then
      base="$(echo "$pcmd" | awk '{print $1}')"
      base="$(basename "$base" 2>/dev/null || echo "$base")"
      if ! is_shell_basename "$base"; then
        sleep 0.2
        tmux send-keys -t "$target" -l "$pcmd" 2>/dev/null || true
        tmux send-keys -t "$target" Enter 2>/dev/null || true
      fi
    fi
  done < <(grep "^P$US$s$US" "$PANELIST" || true)

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

tmux display-message "tsession: restored ${#sessions_ordered[@]} sessions from $SAVE_PATH" 2>/dev/null \
  || echo "tsession: restored ${#sessions_ordered[@]} sessions from $SAVE_PATH"
