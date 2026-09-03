#!/usr/bin/env bash
# Keybind cheatsheet — SUPER+/.
# Reads the live binds out of Hyprland instead of a hand-maintained list, so it
# can never drift out of sync with keybinds.conf.
set -euo pipefail

hyprctl -j binds \
  | jq -r '.[] | "\(.modmask)|\(.key)|\(.dispatcher)|\(.arg)"' \
  | awk -F'|' '
      {
          m = $1 + 0; keys = ""
          # Hyprland modmask bits: SHIFT 1, CAPS 2, CTRL 4, ALT 8, SUPER 64.
          if (and(m, 64)) keys = keys "SUPER + "
          if (and(m,  8)) keys = keys "ALT + "
          if (and(m,  4)) keys = keys "CTRL + "
          if (and(m,  1)) keys = keys "SHIFT + "
          keys = keys $2

          action = $3
          if ($4 != "") action = action " " $4
          printf "%-30s %s\n", keys, action
      }' \
  | sort -u \
  | wofi --dmenu --prompt "Keybinds" --width 900 --height 620 --cache-file /dev/null >/dev/null || true
