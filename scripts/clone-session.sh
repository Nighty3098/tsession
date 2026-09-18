#!/usr/bin/env bash
# Clone a session: duplicate its snapshot and rebuild it live under a new name.
# Usage: clone-session.sh '<src>' '[<dst...>]'
# In the fzf picker the target name comes from the query ({q}); when empty,
# '<src>-copy', '<src>-copy2', ... is picked automatically.

set -euo pipefail

US=$'\x1f'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SRC_RAW="${1:-}"
SRC="$(echo "$SRC_RAW" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
shift || true
DST_RAW="$*"
DST="$(echo "$DST_RAW" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
DST="$(echo "$DST" | tr '.:' '__')"

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

[ -z "$SRC" ] && exit 0

live_src=0
tmux has-session -t "=$SRC" 2>/dev/null && live_src=1 || true

in_file() { [ -f "$SAVE_PATH" ] && grep -q "^[SWPH]$US$1$US" "$SAVE_PATH"; }

# Auto-pick a destination name when none was typed.
if [ -z "$DST" ]; then
  DST="${SRC}-copy"
  n=2
  while tmux has-session -t "=$DST" 2>/dev/null || in_file "$DST"; do
    DST="${SRC}-copy${n}"
    n=$((n + 1))
  done
fi
if [ "$DST" = "$SRC" ]; then
  say "clone: same name"
  exit 1
fi
if tmux has-session -t "=$DST" 2>/dev/null || in_file "$DST"; then
  say "clone: '$DST' already exists (live or saved)"
  exit 1
fi

# 1. Make sure SRC has a snapshot: merge it into the save file.
if [ "$live_src" -eq 1 ]; then
  "$SCRIPT_DIR/save.sh" "$SAVE_PATH" "$SRC" >/dev/null 2>&1 || {
    say "clone: failed to snapshot '$SRC'"
    exit 1
  }
fi
if ! in_file "$SRC"; then
  say "clone: '$SRC' is neither live nor saved"
  exit 1
fi

# 2. Duplicate the snapshot block under the new name.
TMP="$SAVE_PATH.tmp.$$"
awk -v US="$US" -v src="$SRC" -v dst="$DST" '
  BEGIN { FS = US; OFS = US }
  { print }
  /^(S|W|P|H)/ && $2 == src { $0 = $0; $2 = dst; buf[++n] = $0 }
  END { for (i = 1; i <= n; i++) print buf[i] }
' "$SAVE_PATH" > "$TMP"
mv -f "$TMP" "$SAVE_PATH"

# 3. If the source is live, rebuild the copy live too.
if [ "$live_src" -eq 1 ]; then
  "$SCRIPT_DIR/restore.sh" "$SAVE_PATH" "$DST" >/dev/null 2>&1 || {
    say "clone: snapshot copied, live rebuild failed"
    exit 1
  }
  say "cloned '$SRC' → '$DST' (live + snapshot)"
else
  say "cloned snapshot '$SRC' → '$DST'"
fi
