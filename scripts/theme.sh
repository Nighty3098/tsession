#!/usr/bin/env bash
# Shared tsession UI theme.
#
# Accent colours are read from the RUNNING tmux theme — the same options the
# user sets in ~/.tmux.conf — so the manager UI follows whatever palette is
# active (and, through the indexed colours, the terminal theme).
#
# Provided:
#   ACCENT / ACCENT_FG        titles, tags, borders
#                             (pane-active-border-style fg)
#   CURRENT / CURRENT_FG      live / alive highlight
#                             (window-status-current-style bg/fg)
#   MATCH / MATCH_FG          fzf match highlight
#                             (copy-mode-match-style bg/fg)
#   TS_FG                     base text colour (status-style fg)
#   TS_SURFACE                opaque popup surface (status-style bg, black fallback)
#   TS_TITLE_BLOCK etc.       tmux style fragments "bg=..,fg=..,bold"
#   TS_TAG                    tmux style fragment for the status message tag
# Functions:
#   tstyle <opt> <attr> <default>
#   fzf_color <colour>        tmux colour -> fzf colour token
#   sgr_fg <colour> [bold]    foreground SGR escape (bold=1, dim=2)
#   sgr_bg <colour>           background SGR escape

tstyle() {
  local opt="$1" attr="$2" def="$3" val
  val="$(tmux show-option -gqv "$opt" 2>/dev/null || true)"
  [ -z "$val" ] && { printf '%s' "$def"; return; }
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    case "$p" in
      "$attr="*) printf '%s' "${p#*=}"; return ;;
    esac
  done < <(printf '%s' "$val" | tr ',' '\n')
  printf '%s' "$def"
}

name16() {
  case "$1" in
    black) echo 0;; red) echo 1;; green) echo 2;; yellow) echo 3;;
    blue) echo 4;; magenta) echo 5;; cyan) echo 6;; white) echo 7;;
    brightblack) echo 8;; brightred) echo 9;; brightgreen) echo 10;;
    brightyellow) echo 11;; brightblue) echo 12;; brightmagenta) echo 13;;
    brightcyan) echo 14;; brightwhite) echo 15;;
    *) echo "" ;;
  esac
}

hex2rgb() {
  local h="${1#\#}"
  case "${#h}" in
    3) printf '%d %d %d' $((16#${h:0:1} * 17)) $((16#${h:1:1} * 17)) $((16#${h:2:1} * 17)) ;;
    6) printf '%d %d %d' $((16#${h:0:2})) $((16#${h:2:2})) $((16#${h:4:2})) ;;
  esac
}

rgb256() {
  local r="$1" g="$2" b="$3"
  local xr=$(((r * 5 + 127) / 255)) xg=$(((g * 5 + 127) / 255)) xb=$(((b * 5 + 127) / 255))
  echo $((16 + 36 * xr + 6 * xg + xb))
}

fzf_color() {
  local c="$1" n
  case "$c" in
    default|terminal) echo "-1" ;;
    "#"*) echo "$(rgb256 $(hex2rgb "$c"))" ;;
    colour*) echo "${c#colour}" ;;
    *) n="$(name16 "$c")"; [ -n "$n" ] && echo "$n" || echo "$c" ;;
  esac
}

fgcode() {
  local c="$1" n rgb
  case "$c" in
    default|terminal) echo 39 ;;
    "#"*) rgb="$(hex2rgb "$c")"; echo "38;2;${rgb// /;}" ;;
    colour*)
      n="${c#colour}"
      if   [ "$n" -le 7 ];  then echo "$((30 + n))"
      elif [ "$n" -le 15 ]; then echo "$((90 + n - 8))"
      else echo "38;5;$n"; fi ;;
    *)
      n="$(name16 "$c")"
      if   [ -z "$n" ]; then echo 39
      elif [ "$n" -le 7 ];  then echo "$((30 + n))"
      else echo "$((90 + n - 8))"; fi ;;
  esac
}

bgcode() {
  local c="$1" n rgb
  case "$c" in
    default|terminal) echo 49 ;;
    "#"*) rgb="$(hex2rgb "$c")"; echo "48;2;${rgb// /;}" ;;
    colour*)
      n="${c#colour}"
      if   [ "$n" -le 7 ];  then echo "$((40 + n))"
      elif [ "$n" -le 15 ]; then echo "$((100 + n - 8))"
      else echo "48;5;$n"; fi ;;
    *)
      n="$(name16 "$c")"
      if   [ -z "$n" ]; then echo 49
      elif [ "$n" -le 7 ];  then echo "$((40 + n))"
      else echo "$((100 + n - 8))"; fi ;;
  esac
}

sgr_fg() {
  local b="${2:-}"
  printf '\033[%sm' "${b:+$b;}$(fgcode "$1")"
}

sgr_bg() {
  printf '\033[%sm' "$(bgcode "$1")"
}

ACCENT="$(tstyle pane-active-border-style fg red)"
ACCENT_FG="$(tstyle window-status-current-style fg black)"
CURRENT="$(tstyle window-status-current-style bg blue)"
CURRENT_FG="$(tstyle window-status-current-style fg black)"
MATCH="$(tstyle copy-mode-match-style bg green)"
MATCH_FG="$(tstyle copy-mode-match-style fg black)"
TS_FG="$(tstyle status-style fg white)"
TS_BG="$(tstyle status-style bg default)"

[ "$ACCENT" = "default" ] && ACCENT=red
[ "$CURRENT" = "default" ] && CURRENT=blue
[ "$MATCH" = "default" ] && MATCH=green
[ "$TS_FG" = "default" ] && TS_FG=white
# Opaque popup surface: follows status-style bg, falls back to black
# (dark lifted surface) when the terminal default is used.
TS_SURFACE="$TS_BG"
[ "$TS_SURFACE" = "default" ] && TS_SURFACE=black

TS_TITLE_BLOCK="bg=$ACCENT,fg=$ACCENT_FG,bold"
TS_TITLE_CURRENT="bg=$CURRENT,fg=$CURRENT_FG,bold"
TS_TITLE_MATCH="bg=$MATCH,fg=$MATCH_FG,bold"
TS_TAG="#[bg=$ACCENT,fg=$ACCENT_FG,bold] tsession #[default]"

TS_RESET="$(printf '\033[0m')"
TS_ANSI_ALIVE="$(sgr_fg "$CURRENT" 1)"
TS_ANSI_SAVED="$(sgr_fg "$TS_FG" 2)"
TS_ANSI_NAME="$(sgr_fg "$ACCENT" 1)"
TS_ANSI_WIN="$(sgr_fg "$CURRENT" 1)"
TS_ANSI_MARK="$(sgr_fg "$ACCENT" 1)"
TS_ANSI_DOLLAR="$(sgr_fg "$ACCENT" 1)"
TS_ANSI_STATE_LIVE="$(sgr_fg "$MATCH" 1)"
TS_ANSI_STATE_SAVED="$(sgr_fg "$ACCENT" 1)"

TS_FZF_MAIN="bg:$(fzf_color "$TS_SURFACE"),bg+:$(fzf_color "$CURRENT"),fg+:$(fzf_color "$CURRENT_FG"),hl:$(fzf_color "$MATCH"),hl+:$(fzf_color "$MATCH"),gutter:$(fzf_color "$TS_SURFACE")"
TS_FZF_INFO="info:$(fzf_color "$TS_FG"),prompt:$(fzf_color "$TS_FG"),pointer:$(fzf_color "$ACCENT"),marker:$(fzf_color "$ACCENT")"
# InvisibleSurface border for the borderless popup: same colour as the
# surface, so it occupies space (opaque padding) without being seen.
# NOTE: fzf --margin is always transparent — never use it for padding.
TS_FZF_BORDER="border:$(fzf_color "$TS_SURFACE"),scrollbar:$(fzf_color "$TS_SURFACE")"