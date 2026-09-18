#!/usr/bin/env bash
# Preview body for the fzf picker: windows, panes, cwd/cmd of one session.
# Usage: preview-saved.sh '<name>' [save-path]

set -euo pipefail

US=$'\x1f'

NAME_RAW="${1:-}"
NAME="$(echo "$NAME_RAW" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
[ -z "$NAME" ] && exit 0

get_save_path() {
  local p
  p="$(tmux show-option -gqv "@tsession-save-path" 2>/dev/null || true)"
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
  echo "no save file"
  exit 0
fi

b64d() {
  if [ -z "${1:-}" ]; then printf ''; return 0; fi
  printf '%s' "$1" | base64 -d 2>/dev/null || printf '%s' "$1" | base64 -D 2>/dev/null || printf ''
}

short() {
  local s="$1" n="${2:-80}"
  s="$(echo "$s" | tr '\n\r' ' ' | sed 's/[[:space:]][[:space:]]*/ /g;s/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [ "${#s}" -gt "$n" ]; then
    printf '%s...' "${s:0:$((n - 3))}"
  else
    printf '%s' "$s"
  fi
}

tilde() { echo "${1/#$HOME/\~}"; }

nw=0; np=0; nh=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    W"$US$NAME$US"*) nw=$((nw + 1)) ;;
    P"$US$NAME$US"*) np=$((np + 1)) ;;
    H"$US$NAME$US"*) nh=$((nh + 1)) ;;
  esac
done < "$SAVE_PATH"

if tmux has-session -t "=$NAME" 2>/dev/null; then
  state="alive"
else
  state="saved only"
fi
ts="$(head -n 1 "$SAVE_PATH" 2>/dev/null | sed 's/^# tsession save v[0-9]* //')"
echo "$NAME [$state] — ${nw}w/${np}p"
[ -n "$ts" ] && echo "saved: $ts"
[ "$nh" -gt 0 ] && echo "history: $nh panes"
echo

while IFS= read -r wline || [ -n "${wline:-}" ]; do
  [ -z "${wline:-}" ] && continue
  IFS="$US" read -r _ _ws widx wname_b64 wactive _wlayout <<< "$wline"
  wname="$(b64d "$wname_b64")"
  [ -z "$wname" ] && wname="main"
  mark=""; [ "$wactive" = "1" ] && mark=" *"
  echo "#$widx $(short "$wname" 40)$mark"
  while IFS= read -r pline || [ -n "${pline:-}" ]; do
    [ -z "${pline:-}" ] && continue
    IFS="$US" read -r _ _ps _pw pidx pactive cwd_b64 cmd_b64 <<< "$pline"
    pcwd="$(tilde "$(b64d "$cwd_b64")")"
    pcmd="$(b64d "$cmd_b64")"
    pmark=""; [ "$pactive" = "1" ] && pmark="*"
    echo "  .$pidx$pmark $(short "$pcwd" 60)"
    [ -n "$pcmd" ] && echo "    \$ $(short "$pcmd" 80)"
  done < <(grep "^P$US$NAME$US$widx$US" "$SAVE_PATH" || true)
done < <(grep "^W$US$NAME$US" "$SAVE_PATH" || true)

if [ "$state" = "alive" ]; then
  echo
  echo "--- live ---"
  tmux list-windows -t "=$NAME" -F '#{window_index}:#{window_name} (#{window_panes} panes)' 2>/dev/null || true
fi
