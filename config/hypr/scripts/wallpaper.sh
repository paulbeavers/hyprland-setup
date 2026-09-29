#!/usr/bin/env bash
# Wallpaper picker — SUPER + W. Uses wofi so it matches the launcher.
#
# Offers two sources: your own images in ~/Pictures/wallpapers, and the
# wallpapers Hyprland ships in /usr/share/hypr (wall0-2). The system ones are
# read in place rather than copied — they are 13-27MB each, and an update to
# the hyprland package brings in whatever it ships next.
#
#     wallpaper.sh              open the picker
#     wallpaper.sh --set <path> apply one image directly
#     wallpaper.sh --random     set a random one, no menu (handy in autostart)
#     wallpaper.sh --restore    re-apply the recorded choice (install time)
#     wallpaper.sh --print      list what would be offered, one path per line
#     wallpaper.sh --no-reload  record the choice but do not put it on screen
#
# The choice is recorded in ~/.config/hypr/.active-wallpaper, and hyprlock.conf
# is rewritten from it so the lock screen matches. Both are files the installer
# syncs, so --restore is how a re-run puts your pick back after the sync.
#
# The wallpaper itself is drawn by swaybg, which takes the image as an argument
# — no daemon, no socket, nothing to wait for. It replaced hyprpaper, whose
# apply is an IPC call that answers "ok" whether or not it painted anything,
# and which on install media never answered at all.
set -euo pipefail

CFG="${XDG_CONFIG_HOME:-$HOME/.config}"
WALLPAPER_DIR="${WALLPAPER_DIR:-$HOME/Pictures/wallpapers}"
SYSTEM_DIR="${SYSTEM_WALLPAPER_DIR:-/usr/share/hypr}"
HYPRLOCK_CONF="${HYPRLOCK_CONF:-$CFG/hypr/hyprlock.conf}"
ACTIVE_FILE="${ACTIVE_WALLPAPER_FILE:-$CFG/hypr/.active-wallpaper}"
LIVE=1

note() { command -v notify-send >/dev/null && notify-send -a Wallpaper "$@" || true; }

die() {
    printf 'wallpaper.sh: %s\n' "$1" >&2
    note "Wallpaper" "$1"
    exit 1
}

FILES=()   # absolute paths
LABELS=()  # what the menu shows, one per path, unique

# Both sources, NUL-safe throughout so spaces and other awkward characters in a
# filename survive. Labels are prefixed for the system set, which keeps them
# unique even if you happen to have your own wall0.png.
collect() {
    local f
    FILES=(); LABELS=()

    if [[ -d $WALLPAPER_DIR ]]; then
        while IFS= read -r -d '' f; do
            FILES+=("$f"); LABELS+=("${f##*/}")
        done < <(
            find -L "$WALLPAPER_DIR" -maxdepth 1 -type f \
                \( -iname '*.png'  -o -iname '*.jpg' -o -iname '*.jpeg' \
                -o -iname '*.webp' -o -iname '*.bmp' -o -iname '*.gif' \) \
                -print0 2>/dev/null | sort -z
        )
    fi

    # Only wall*.png — /usr/share/hypr also holds lockdead*.png, which are the
    # "you died" lock screens, not wallpapers.
    if [[ -d $SYSTEM_DIR ]]; then
        while IFS= read -r -d '' f; do
            FILES+=("$f"); LABELS+=("Hyprland — ${f##*/}")
        done < <(
            find -L "$SYSTEM_DIR" -maxdepth 1 -type f -iname 'wall*.png' \
                -print0 2>/dev/null | sort -z
        )
    fi

    [[ ${#FILES[@]} -gt 0 ]] \
        || die "no images in $WALLPAPER_DIR or $SYSTEM_DIR"
}

# Record the choice, then put it on screen with swaybg.
apply() {
    local img="$1"
    [[ -f $img ]] || die "no such image: $img"
    persist_lock "$img"
    mkdir -p "${ACTIVE_FILE%/*}"
    printf '%s\n' "$img" > "$ACTIVE_FILE"

    # Recording it is the part that must always happen. Putting it on screen is
    # skipped under --no-reload, and during an install there is no session to
    # put it on.
    [[ $LIVE -eq 1 ]] || return 0

    # swaybg takes the image as an argument, so there is no daemon protocol, no
    # socket to appear and nothing to race. That is the whole reason it is here.
    # hyprpaper's apply is an hyprctl call that returns "ok" whether or not it
    # has a surface to paint on, and 0.8.4 offers no way to ask what it is
    # showing — so three rounds of timeout tuning could not tell a lost race
    # from a call that succeeded and drew nothing. On the medium it never
    # answered at all: "did not answer in 10s", then "would not accept", after
    # twenty seconds of waiting, on every boot.
    #
    # Changing the wallpaper means replacing the process. Start the new one
    # before killing the old so the bare compositor never shows between them.
    local log="${WALLPAPER_LOG:-/tmp/wallpaper.log}" old new

    # Say so plainly when the package is missing. `install.sh --configs-only`
    # deploys this script without touching packages, so a machine configured
    # that way gets the swaybg version of it while still having hyprpaper
    # installed — and "nothing happens when I change the wallpaper" is a
    # miserable way to find that out.
    if ! command -v swaybg >/dev/null 2>&1; then
        printf '%s swaybg is not installed; cannot draw %s\n' "$(date +%T)" "$img" >> "$log" 2>/dev/null
        die "swaybg is not installed — pacman -S swaybg (or re-run install.sh)"
    fi

    old="$(pgrep -x swaybg 2>/dev/null | tr '\n' ' ')"

    # No --output: swaybg applies to every output when none is named, which is
    # what we want and one fewer thing to quote.
    swaybg --image "$img" --mode fill >/dev/null 2>&1 &
    new=$!

    # Long enough to have failed. swaybg exits on an unreadable image, and a
    # dead one looks exactly like a working one if nobody checks.
    sleep 0.5
    if ! kill -0 "$new" 2>/dev/null; then
        printf '%s swaybg exited immediately for %s\n' "$(date +%T)" "$img" >> "$log" 2>/dev/null
        die "swaybg would not display $img"
    fi

    if [[ -n ${old// /} ]]; then
        kill $old 2>/dev/null || true
    fi
    printf '%s swaybg pid %s showing %s\n' "$(date +%T)" "$new" "$img" >> "$log" 2>/dev/null
    return 0
}

# Keep the lock screen on the same image. Only the `path` inside hyprlock's
# background block is touched; everything else is left alone.
persist_lock() {
    local img="$1" tmp
    [[ -w $HYPRLOCK_CONF ]] || return 0
    tmp="$(mktemp "${HYPRLOCK_CONF}.XXXXXX")" || return 0
    if awk -v img="$img" '
        /^background[[:space:]]*\{/ { inbg = 1 }
        inbg && /^[[:space:]]*path[[:space:]]*=/ {
            print "    path = " img; next
        }
        inbg && /^\}/ { inbg = 0 }
        { print }
    ' "$HYPRLOCK_CONF" > "$tmp"; then
        chmod 644 "$tmp"; mv "$tmp" "$HYPRLOCK_CONF"
    else
        rm -f "$tmp"
    fi
}

# --no-reload can precede any other argument.
if [[ ${1:-} == --no-reload ]]; then LIVE=0; shift; fi

case "${1:-}" in
    --set)
        [[ -n ${2:-} ]] || die "--set needs an image path"
        apply "$2"
        ;;
    --restore)
        [[ -r $ACTIVE_FILE ]] || exit 0
        img="$(<"$ACTIVE_FILE")"
        [[ -n $img && -f $img ]] || exit 0
        apply "$img"
        ;;
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
        # swaybg has no IPC to ask, and the recorded choice is what it was
        # started from, so the file is the answer.
        current="$([[ -r $ACTIVE_FILE ]] && <"$ACTIVE_FILE" || true)"
        choice="$(printf '%s\n' "${LABELS[@]}" \
            | wofi --dmenu --prompt "Wallpaper${current:+ (${current##*/})}" \
                   --width 520 --height 420 --cache-file /dev/null --insensitive)" || exit 0
        [[ -n $choice ]] || exit 0
        # Labels are unique, so the first match is the right one.
        for i in "${!LABELS[@]}"; do
            if [[ ${LABELS[i]} == "$choice" ]]; then apply "${FILES[i]}"; exit 0; fi
        done
        die "no wallpaper named $choice"
        ;;
    *)
        die "unknown option: $1 (try --set, --random, --restore or --print)"
        ;;
esac
