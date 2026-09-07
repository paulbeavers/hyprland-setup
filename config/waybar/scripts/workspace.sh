#!/usr/bin/env bash
# workspace.sh N — describe workspace N for waybar, as one line of JSON.
#
# This exists because waybar's own hyprland/workspaces module cannot switch
# workspaces on a Lua-configured Hyprland. It hardcodes the IPC request
#
#     dispatch workspace 3
#
# and Hyprland, when its config is Lua, evaluates everything after `dispatch`
# as Lua: `hl.dispatch(workspace 3)` is a syntax error, so the click does
# nothing and nothing is reported anywhere. Waybar has no setting for the
# string it sends, so the only way to get a working click is to draw the row
# ourselves out of custom modules, each with its own on-click.
#
# Output classes match the CSS: active, urgent, occupied, empty.
set -euo pipefail

# Workspaces up to here are always shown, empty or not. Above it, a workspace
# appears only while something is on it — waybar hides a custom module whose
# text is empty, which is how the row grows and shrinks.
PERSISTENT=5

n="${1:?usage: workspace.sh <number>}"

active="$(hyprctl activeworkspace -j 2>/dev/null | jq -r '.id // 0')"
read -r count urgent < <(
    hyprctl clients -j 2>/dev/null |
        jq -r --argjson n "$n" '
            map(select(.workspace.id == $n)) as $ws
            | "\($ws | length) \($ws | map(select(.urgent)) | length)"
        '
)

if   [[ $active == "$n" ]]; then class=active
elif (( urgent > 0 ));     then class=urgent
elif (( count > 0 ));      then class=occupied
else                            class=empty
fi

text="$n"
[[ $class == empty && $n -gt $PERSISTENT ]] && text=""

printf '{"text":"%s","class":"%s"}\n' "$text" "$class"
