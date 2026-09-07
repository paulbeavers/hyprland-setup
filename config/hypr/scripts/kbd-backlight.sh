#!/usr/bin/env bash
# Keyboard backlight, on whichever machine this is.
#
#     kbd-backlight.sh up      brighter
#     kbd-backlight.sh down    dimmer
#     kbd-backlight.sh toggle  off, or back to where it was
#
# The device name is vendor-specific — smc::kbd_backlight on a MacBook,
# tpacpi::kbd_backlight on a ThinkPad, asus::kbd_backlight and others
# elsewhere — so it is found rather than hardcoded. A machine with no backlit
# keyboard has no such device and this exits quietly, which is what makes the
# keybinds safe to ship to desktops that will never fire them.
set -uo pipefail

DEV=""
for d in /sys/class/leds/*kbd_backlight*; do
    [[ -d $d ]] || continue
    DEV="$(basename "$d")"
    break
done
[[ -n $DEV ]] || exit 0

STATE="${XDG_RUNTIME_DIR:-/tmp}/kbd-backlight.last"

case "${1:-}" in
    up)   brightnessctl --device="$DEV" set +10% >/dev/null ;;
    down) brightnessctl --device="$DEV" set 10%- >/dev/null ;;
    toggle)
        now="$(brightnessctl --device="$DEV" get 2>/dev/null || echo 0)"
        if [[ ${now:-0} -gt 0 ]]; then
            printf '%s\n' "$now" > "$STATE"
            brightnessctl --device="$DEV" set 0 >/dev/null
        else
            brightnessctl --device="$DEV" set "$(cat "$STATE" 2>/dev/null || echo 50%)" >/dev/null
        fi
        ;;
    *) echo "usage: ${0##*/} up|down|toggle" >&2; exit 2 ;;
esac

# Show the same on-screen indicator the display brightness keys use, so the two
# behave alike. Silent if swayosd is not running.
command -v swayosd-client >/dev/null &&
    swayosd-client --custom-progress "$(
        awk -v v="$(brightnessctl --device="$DEV" get)" \
            -v m="$(brightnessctl --device="$DEV" max)" \
            'BEGIN { printf "%.2f", (m ? v/m : 0) }'
    )" --custom-icon keyboard-brightness 2>/dev/null || true
