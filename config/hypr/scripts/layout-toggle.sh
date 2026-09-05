#!/usr/bin/env bash
# Layout toggle — SUPER + T. Flips general:layout between dwindle and scrolling.
#
#     layout-toggle.sh            toggle
#     layout-toggle.sh dwindle    force a specific layout
#     layout-toggle.sh scrolling
#     layout-toggle.sh --print    print the current layout and exit
#
# The switch is a runtime `hyprctl keyword`, so it re-tiles the open windows
# immediately but does not touch theme.conf: `hyprctl reload` (or a fresh
# session) puts you back on whatever theme.conf sets as the default.
set -euo pipefail

note() { command -v notify-send >/dev/null && notify-send -a Layout -t 1500 "$@" || true; }

current() { hyprctl getoption general:layout -j | jq -r '.str'; }

case "${1-}" in
    --print)             current; exit 0 ;;
    dwindle|scrolling)   next="$1" ;;
    "")                  [[ "$(current)" == scrolling ]] && next=dwindle || next=scrolling ;;
    *)                   echo "usage: layout-toggle.sh [dwindle|scrolling|--print]" >&2; exit 2 ;;
esac

hyprctl keyword general:layout "$next" >/dev/null

case "$next" in
    scrolling) note "Scrolling" "Windows on an endless tape. SUPER + - / = resizes a column." ;;
    dwindle)   note "Dwindle"   "Back to binary-split tiling." ;;
esac
