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
#     wallpaper.sh --no-reload  write the configs but do not talk to hyprpaper
#
# The choice is recorded in ~/.config/hypr/.active-wallpaper. hyprpaper.conf and
# hyprlock.conf are both rewritten from it, and both are files the installer
# syncs, so --restore is how a re-run puts your pick back after the sync.
#
# Note: hyprpaper v0.8.4 rejects `preload`, `reload` and `unload` over hyprctl
# — `wallpaper` is the only verb it accepts, and it loads the image itself, so
# that single call is the whole apply path.
set -euo pipefail

CFG="${XDG_CONFIG_HOME:-$HOME/.config}"
WALLPAPER_DIR="${WALLPAPER_DIR:-$HOME/Pictures/wallpapers}"
SYSTEM_DIR="${SYSTEM_WALLPAPER_DIR:-/usr/share/hypr}"
HYPRPAPER_CONF="${HYPRPAPER_CONF:-$CFG/hypr/hyprpaper.conf}"
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

# Point hyprpaper at the image, then make it stick. Restarting the daemon is
# the fallback for the very first run, when nothing is listening yet.
apply() {
    local img="$1"
    [[ -f $img ]] || die "no such image: $img"
    persist "$img"
    persist_lock "$img"
    mkdir -p "${ACTIVE_FILE%/*}"
    printf '%s\n' "$img" > "$ACTIVE_FILE"

    # Writing the configs is the part that must always happen. Talking to the
    # daemon is skipped under --no-reload, and during an install there is no
    # session to talk to anyway.
    [[ $LIVE -eq 1 ]] || return 0

    # This IPC call is the only thing that actually puts an image on screen.
    # hyprpaper does not apply wallpapers from its own config file — it finds
    # the output, logs "Monitor <name> has no target: no wp will be created"
    # and draws nothing — so the configs written above are a record of the
    # choice, not the mechanism.
    #
    # autostart.lua starts hyprpaper and calls this script in the same breath,
    # so the first attempts land before hyprpaper's socket exists. That is a
    # race, and it has to be waited out rather than guessed at: the previous
    # version waited a single second, and on install media — reading hyprpaper
    # and its libraries off the medium with a cold cache — that was not close
    # to enough. Worse, it killed the hyprpaper autostart had just started and
    # then died, so the desktop came up black.
    for _ in $(seq 1 40); do
        hyprctl hyprpaper wallpaper ",$img" >/dev/null 2>&1 && return 0
        sleep 0.25
    done

    # Ten seconds without an answer means hyprpaper is not running or is
    # wedged, which is the only case where restarting it is the right move.
    pkill -x hyprpaper 2>/dev/null || true
    hyprpaper >/dev/null 2>&1 &
    for _ in $(seq 1 20); do
        sleep 0.25
        hyprctl hyprpaper wallpaper ",$img" >/dev/null 2>&1 && return 0
    done
    die "hyprpaper would not accept $img"
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
    tmp="$(mktemp "${HYPRPAPER_CONF}.XXXXXX")" || return 0
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
        chmod 644 "$tmp"; mv "$tmp" "$HYPRPAPER_CONF"
    else
        rm -f "$tmp"
    fi
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
        current="$(hyprctl hyprpaper listactive 2>/dev/null | head -1 | cut -d' ' -f2- || true)"
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
