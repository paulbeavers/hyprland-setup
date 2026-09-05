#!/usr/bin/env bash
# Layout toggle — SUPER + T. Flips general:layout between dwindle and scrolling.
#
#     layout-toggle.sh            toggle
#     layout-toggle.sh dwindle    force a specific layout
#     layout-toggle.sh scrolling
#     layout-toggle.sh --print    print the current layout and exit
#
# The switch is a runtime `hyprctl eval`, so it re-tiles the open windows
# immediately but does not touch theme.lua: a fresh session puts you back on
# whatever theme.lua sets as the default.
#
# `hyprctl keyword` is not usable here — the Lua config manager rejects it with
# "keyword can't work with non-legacy parsers. Use eval." `getoption` is still
# fine, so reading the current layout is unchanged.
set -euo pipefail

note() { command -v notify-send >/dev/null && notify-send -a Layout -t 1500 "$@" || true; }

current() { hyprctl getoption general:layout -j | jq -r '.str'; }

case "${1-}" in
    --print)             current; exit 0 ;;
    dwindle|scrolling)   next="$1" ;;
    "")                  [[ "$(current)" == scrolling ]] && next=dwindle || next=scrolling ;;
    *)                   echo "usage: layout-toggle.sh [dwindle|scrolling|--print]" >&2; exit 2 ;;
esac

hyprctl eval "hl.config({ general = { layout = \"$next\" } })" >/dev/null

case "$next" in
    scrolling) note "Scrolling" "Windows on an endless tape. SUPER + - / = resizes a column." ;;
    dwindle)   note "Dwindle"   "Back to binary-split tiling." ;;
esac
