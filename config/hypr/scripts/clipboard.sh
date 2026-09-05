#!/usr/bin/env bash
# Mac-style clipboard — SUPER + C copies, SUPER + V pastes.
#
#     clipboard.sh copy
#     clipboard.sh paste
#     clipboard.sh --print    name the shortcut that would be sent, and exit
#
# Hyprland grabs SUPER+C/V before the focused app ever sees them, so the bind
# has to hand the app the shortcut it actually understands. That is not the
# same everywhere: in a terminal Ctrl+C is SIGINT, and copy/paste are
# Ctrl+Shift+C/V. So the class of the focused window decides which one is sent.
set -euo pipefail

# Matched case-insensitively against the window class, as full-string globs.
TERMINALS='kitty|foot|footclient|alacritty|*wezterm*|*ghostty*|xterm|urxvt|st|
           org.kde.konsole|konsole|terminator|tilix|*gnome-terminal*|*xfce4-terminal*'

is_terminal() {
    local class="${1,,}" pat
    while IFS= read -r pat; do
        pat="${pat//[[:space:]]/}"
        [[ -n $pat ]] || continue
        # shellcheck disable=SC2053  -- the glob on the right is the point.
        [[ $class == $pat ]] && return 0
    done < <(tr '|' '\n' <<<"$TERMINALS")
    return 1
}

shortcut_for() {
    if is_terminal "$1"; then printf 'CTRL SHIFT'; else printf 'CTRL'; fi
}

case "${1:-}" in
    copy)  key=C ;;
    paste) key=V ;;
    --print)
        class="$(hyprctl activewindow -j 2>/dev/null | jq -r '.class // ""')"
        printf '%s -> %s\n' "${class:-<none>}" "$(shortcut_for "$class")"
        exit 0
        ;;
    *) printf 'usage: clipboard.sh {copy|paste|--print}\n' >&2; exit 2 ;;
esac

class="$(hyprctl activewindow -j 2>/dev/null | jq -r '.class // ""')"
# No focused window means nothing to send to.
[[ -n $class ]] || exit 0

hyprctl dispatch sendshortcut "$(shortcut_for "$class"), $key, activewindow" >/dev/null
