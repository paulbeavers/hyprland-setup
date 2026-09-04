#!/usr/bin/env bash
# Wallpaper picker — SUPER + W. Uses wofi so it matches the launcher.
#
# Lists the images in ~/Pictures/wallpapers, sets the pick on every output,
# and rewrites hyprpaper.conf so the choice survives a restart.
#
#     wallpaper.sh              open the picker
#     wallpaper.sh --random     set a random one, no menu (handy in autostart)
#     wallpaper.sh --print      list what would be offered, one path per line
#
# Note: hyprpaper v0.8.4 rejects `preload`, `reload` and `unload` over hyprctl
# — `wallpaper` is the only verb it accepts, and it loads the image itself, so
# that single call is the whole apply path.
set -euo pipefail

WALLPAPER_DIR="${WALLPAPER_DIR:-$HOME/Pictures/wallpapers}"
HYPRPAPER_CONF="${HYPRPAPER_CONF:-$HOME/.config/hypr/hyprpaper.conf}"

note() { command -v notify-send >/dev/null && notify-send -a Wallpaper "$@" || true; }

die() {
    printf 'wallpaper.sh: %s\n' "$1" >&2
    note "Wallpaper" "$1"
    exit 1
}

# Every image directly in WALLPAPER_DIR, sorted, NUL-safe so that spaces and
# other awkward characters in a filename survive.
collect() {
    [[ -d $WALLPAPER_DIR ]] || die "no such directory: $WALLPAPER_DIR"
    mapfile -d '' -t FILES < <(
        find -L "$WALLPAPER_DIR" -maxdepth 1 -type f \
            \( -iname '*.png'  -o -iname '*.jpg' -o -iname '*.jpeg' \
            -o -iname '*.webp' -o -iname '*.bmp' -o -iname '*.gif' \) \
            -print0 | sort -z
    )
    [[ ${#FILES[@]} -gt 0 ]] || die "no images in $WALLPAPER_DIR"
}

# Point hyprpaper at the image, then make it stick. Restarting the daemon is
# the fallback for the very first run, when nothing is listening yet.
apply() {
    local img="$1"
    if ! hyprctl hyprpaper wallpaper ",$img" >/dev/null 2>&1; then
        pkill -x hyprpaper 2>/dev/null || true
        hyprpaper >/dev/null 2>&1 &
        sleep 1
        hyprctl hyprpaper wallpaper ",$img" >/dev/null 2>&1 \
            || die "hyprpaper would not accept $img"
    fi
    persist "$img"
}

# Rewrite the preload/wallpaper lines in place, leaving the comments alone.
# The path goes in through -v so nothing in it is read as a regex.
#
# This collapses the file down to a single wallpaper on every output. If you
# ever hand-write per-monitor `wallpaper = DP-3, ...` lines, stop using the
# picker or it will flatten them.
persist() {
    local img="$1" tmp
    [[ -w $HYPRPAPER_CONF ]] || return 0
    tmp="$(mktemp)" || return 0
    if awk -v img="$img" '
        /^[[:space:]]*preload[[:space:]]*=/ {
            if (!p) { print "preload = " img; p = 1 }
            next
        }
        /^[[:space:]]*wallpaper[[:space:]]*=/ {
            if (!w) { print "wallpaper = , " img; w = 1 }
            next
        }
        { print }
        END {
            if (!p) print "preload = " img
            if (!w) print "wallpaper = , " img
        }
    ' "$HYPRPAPER_CONF" > "$tmp"; then
        cat "$tmp" > "$HYPRPAPER_CONF"
    fi
    rm -f "$tmp"
}

case "${1:-}" in
    --print)
        collect
        printf '%s\n' "${FILES[@]}"
        ;;
    --random)
        collect
        apply "${FILES[RANDOM % ${#FILES[@]}]}"
        ;;
    "")
        collect
        current="$(hyprctl hyprpaper listactive 2>/dev/null | head -1 | cut -d' ' -f2- || true)"
        # Basenames are unique inside one directory, so the menu can show them
        # bare and the choice maps straight back to a path.
        choice="$(printf '%s\n' "${FILES[@]##*/}" \
            | wofi --dmenu --prompt "Wallpaper${current:+ (${current##*/})}" \
                   --width 520 --height 420 --cache-file /dev/null --insensitive)" || exit 0
        [[ -n $choice ]] || exit 0
        [[ -f "$WALLPAPER_DIR/$choice" ]] || die "no such image: $choice"
        apply "$WALLPAPER_DIR/$choice"
        ;;
    *)
        die "unknown option: $1 (try --random or --print)"
        ;;
esac
