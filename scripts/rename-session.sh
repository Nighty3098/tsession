#!/usr/bin/env bash
# Rename a session live and/or in the save file.
# Usage: rename-session.sh '<old>' '<new...>'
# In the fzf picker the new name comes from the query ({q}), so all args
# after <old> are joined with spaces.

set -euo pipefail

US=$'\x1f'

OLD_RAW="${1:-}"
OLD="$(echo "$OLD_RAW" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
shift || true
NEW_RAW="$*"
NEW="$(echo "$NEW_RAW" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
NEW="$(echo "$NEW" | tr '.:' '__')"
[ -z "$OLD" ] && exit 0

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

SAVE_PATH="$(get_save_path)"

say() {
  tmux display-message "tsession: $1" 2>/dev/null || echo "tsession: $1"
}

if [ -z "$NEW" ]; then
  say "rename: empty new name (type it in the filter, then press R)"
  exit 1
fi
if [ "$NEW" = "$OLD" ]; then
  say "rename: same name"
  exit 1
fi

live_old=0; live_new=0
tmux has-session -t "=$OLD" 2>/dev/null && live_old=1 || true
tmux has-session -t "=$NEW" 2>/dev/null && live_new=1 || true
if [ "$live_new" -eq 1 ]; then
  say "rename: live session '$NEW' already exists"
  exit 1
fi

renamed_snapshot=0
if [ -f "$SAVE_PATH" ] && grep -q "^[SWPH]$US$OLD$US" "$SAVE_PATH"; then
  TMP="$SAVE_PATH.tmp.$$"
  awk -v US="$US" -v old="$OLD" -v new="$NEW" '
    BEGIN { FS = US; OFS = US }
    /^(S|W|P|H)/ && $2 == old { $2 = new }
    { print }
  ' "$SAVE_PATH" > "$TMP"
  mv -f "$TMP" "$SAVE_PATH"
  renamed_snapshot=1
fi

if [ "$live_old" -eq 1 ]; then
  tmux rename-session -t "=$OLD" "$NEW" 2>/dev/null || {
    say "rename: failed to rename live '$OLD'"
    exit 1
  }
  if [ "$renamed_snapshot" -eq 1 ]; then
    say "renamed '$OLD' → '$NEW' (live + snapshot)"
  else
    say "renamed live '$OLD' → '$NEW' (no snapshot)"
  fi
else
  if [ "$renamed_snapshot" -eq 1 ]; then
    say "renamed snapshot '$OLD' → '$NEW'"
  else
    say "nothing to rename: '$OLD'"
    exit 1
  fi
fi
