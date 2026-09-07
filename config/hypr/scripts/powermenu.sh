#!/usr/bin/env bash
# Power menu — SUPER+SHIFT+E. Uses wofi so it matches the launcher.
set -euo pipefail

lock="  Lock"
logout="  Log out"
suspend="  Suspend"
reboot="  Reboot"
shutdown="  Shut down"

choice=$(printf '%s\n' "$lock" "$logout" "$suspend" "$reboot" "$shutdown" \
    | wofi --dmenu --prompt "Power" --width 260 --height 260 --cache-file /dev/null)

case "$choice" in
    "$lock")     loginctl lock-session ;;
    "$logout")   hyprctl dispatch 'hl.dsp.exit()' ;;
    "$suspend")  systemctl suspend ;;
    "$reboot")   systemctl reboot ;;
    "$shutdown") systemctl poweroff ;;
esac
