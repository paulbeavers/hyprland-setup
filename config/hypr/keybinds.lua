--------------------------------------------------------------------------------
--  Keybinds
--
--  hl.bind(key, dispatcher, opts?). The old bind flag letters became opts:
--    binde -> { repeating = true }      bindl -> { locked = true }
--    bindm -> { mouse = true }          bindn -> { non_consuming = true }
--
--  Find a key's name with:  wev
--------------------------------------------------------------------------------

local p   = require("programs")
local mod = "SUPER"

-- hyprctl reports every Lua bind's dispatcher as "__lua", so the SUPER+/
-- cheatsheet has nothing to show unless each bind carries a description.
-- This wrapper makes the description a required third argument.
local function bind(key, dispatcher, desc, opts)
    opts = opts or {}
    opts.description = desc
    hl.bind(key, dispatcher, opts)
end

-- ── launching ───────────────────────────────────────────────────────────────
bind(mod .. " + Return", hl.dsp.exec_cmd(p.terminal), "Terminal")
bind(mod .. " + D",      hl.dsp.exec_cmd(p.menu), "App launcher")
bind(mod .. " + E",      hl.dsp.exec_cmd(p.file_manager), "File manager")
bind(mod .. " + B",      hl.dsp.exec_cmd(p.browser), "Browser")
bind(mod .. " + N",      hl.dsp.exec_cmd(p.editor), "Editor")

-- Window rules used to be a [float; size ...] prefix on the command; they are
-- now a second argument to exec_cmd.
bind(mod .. " + SHIFT + Return",
    hl.dsp.exec_cmd(p.terminal, { float = true, size = { 1000, 650 }, center = true }),
    "Floating terminal")

-- ── window management ───────────────────────────────────────────────────────
bind(mod .. " + Q", hl.dsp.window.close(), "Close window")
bind(mod .. " + P", hl.dsp.window.pseudo(), "Pseudo-tile (dwindle)")            -- dwindle: fake-tile
bind(mod .. " + J", hl.dsp.layout("togglesplit"), "Flip split axis (dwindle)")      -- dwindle: flip split
bind(mod .. " + F",         hl.dsp.window.fullscreen({ mode = "fullscreen" }), "Fullscreen")
bind(mod .. " + SHIFT + F", hl.dsp.window.fullscreen({ mode = "maximized" }), "Maximise within gaps")
bind(mod .. " + SHIFT + P", hl.dsp.window.pin(), "Pin across workspaces")

-- SUPER+C and SUPER+V are the clipboard (below), so these moved one modifier on.
bind(mod .. " + CTRL + V", hl.dsp.window.float({ action = "toggle" }), "Toggle floating")
bind(mod .. " + CTRL + C", hl.dsp.window.center(), "Centre window")

-- Exit Hyprland. Deliberately awkward so you cannot hit it by accident.
bind(mod .. " + SHIFT + M", hl.dsp.exit(), "Exit Hyprland")

-- ── focus ───────────────────────────────────────────────────────────────────
for key, dir in pairs({ left = "l", right = "r", up = "u", down = "d" }) do
    bind(mod .. " + " .. key, hl.dsp.focus({ direction = dir }), "Focus " .. key)
end
-- Vim keys do the same. SUPER+J is togglesplit, so "focus down" is arrow-only.
bind(mod .. " + H", hl.dsp.focus({ direction = "l" }), "Focus left")
bind(mod .. " + L", hl.dsp.focus({ direction = "r" }), "Focus right")
bind(mod .. " + K", hl.dsp.focus({ direction = "u" }), "Focus up")

-- Two dispatchers on one key: hyprlang allowed two bind lines for the same
-- combo, Lua takes one dispatcher per bind, so a function runs both.
bind("ALT + Tab", function()
    hl.dispatch(hl.dsp.window.cycle_next())
    hl.dispatch(hl.dsp.window.alter_zorder({ mode = "top" }))
end, "Cycle windows")
bind(mod .. " + grave", hl.dsp.focus({ last = true }), "Last window")

-- ── moving windows ──────────────────────────────────────────────────────────
-- `movewindow <dir>` has no direct Lua equivalent: window.move only takes a
-- workspace, monitor, coords or a group. Swapping with the neighbour in that
-- direction is what the old dispatcher actually did in a tiled layout.
for key, dir in pairs({ left = "l", right = "r", up = "u", down = "d" }) do
    bind(mod .. " + SHIFT + " .. key, hl.dsp.window.swap({ direction = dir }), "Move window " .. key)
end
bind(mod .. " + SHIFT + H", hl.dsp.window.swap({ direction = "l" }), "Move window left")
bind(mod .. " + SHIFT + L", hl.dsp.window.swap({ direction = "r" }), "Move window right")
bind(mod .. " + SHIFT + K", hl.dsp.window.swap({ direction = "u" }), "Move window up")
bind(mod .. " + SHIFT + J", hl.dsp.window.swap({ direction = "d" }), "Move window down")

-- ── resizing ────────────────────────────────────────────────────────────────
-- window.resize() with no arguments starts an *interactive* resize. A stepped
-- resize needs relative = true, which is what the old `resizeactive` did.
local step = {
    left  = { x = -40, y =   0 },
    right = { x =  40, y =   0 },
    up    = { x =   0, y = -40 },
    down  = { x =   0, y =  40 },
}
for key, d in pairs(step) do
    bind(mod .. " + CTRL + " .. key,
        hl.dsp.window.resize({ x = d.x, y = d.y, relative = true }),
        "Resize " .. key, { repeating = true })
end

-- Drag anywhere in the window rather than having to grab a border.
bind(mod .. " + mouse:272", hl.dsp.window.drag(),   "Drag window",   { mouse = true })
bind(mod .. " + mouse:273", hl.dsp.window.resize(), "Resize window", { mouse = true })

-- ── layout ──────────────────────────────────────────────────────────────────
-- Toggle dwindle <-> scrolling. Runtime only: theme.lua still decides which
-- layout a fresh session starts in.
bind(mod .. " + T", hl.dsp.exec_cmd("~/.config/hypr/scripts/layout-toggle.sh"), "Toggle dwindle/scrolling")

-- Scrolling only. Under dwindle these are harmless no-ops.
bind(mod .. " + minus",         hl.dsp.layout("colresize -conf"), "Narrower column")
bind(mod .. " + equal",         hl.dsp.layout("colresize +conf"), "Wider column")
bind(mod .. " + SHIFT + equal", hl.dsp.layout("colresize expand"), "Column fills screen")
bind(mod .. " + ALT + H",       hl.dsp.layout("move -col"), "Shift column left")
bind(mod .. " + ALT + L",       hl.dsp.layout("move +col"), "Shift column right")
bind(mod .. " + ALT + comma",   hl.dsp.layout("focus tobeg"), "Jump to tape start")
bind(mod .. " + ALT + period",  hl.dsp.layout("focus toend"), "Jump to tape end")
bind(mod .. " + ALT + Return",  hl.dsp.layout("promote"), "Window to own column")
bind(mod .. " + ALT + C",       hl.dsp.layout("consume_or_expel +col"), "Consume/expel column")
bind(mod .. " + ALT + V",       hl.dsp.layout("fit_into_view"), "Fit into view")

-- ── workspaces ──────────────────────────────────────────────────────────────
for i = 1, 10 do
    local key = i % 10  -- 10 is bound to the 0 key
    bind(mod .. " + " .. key,         hl.dsp.focus({ workspace = i }),       "Workspace " .. i)
    bind(mod .. " + SHIFT + " .. key, hl.dsp.window.move({ workspace = i }), "Window to workspace " .. i)
end

-- Send it there without following. `follow = false` is the old "silent".
for i = 1, 5 do
    bind(mod .. " + CTRL + " .. i, hl.dsp.window.move({ workspace = i, follow = false }),
        "Window to workspace " .. i .. " (silent)")
end

-- Scroll through workspaces. "m" = monitor-relative, so it stays on screen.
bind(mod .. " + Tab",          hl.dsp.focus({ workspace = "m+1" }), "Next workspace")
bind(mod .. " + SHIFT + Tab",  hl.dsp.focus({ workspace = "m-1" }), "Previous workspace")
bind(mod .. " + bracketleft",  hl.dsp.focus({ workspace = "m-1" }), "Previous workspace")
bind(mod .. " + bracketright", hl.dsp.focus({ workspace = "m+1" }), "Next workspace")
bind(mod .. " + mouse_down",   hl.dsp.focus({ workspace = "m+1" }), "Next workspace")
bind(mod .. " + mouse_up",     hl.dsp.focus({ workspace = "m-1" }), "Previous workspace")

-- Scratchpad — a workspace that floats over whatever you are doing.
bind(mod .. " + S",       hl.dsp.workspace.toggle_special("magic"), "Scratchpad")
bind(mod .. " + ALT + S", hl.dsp.window.move({ workspace = "special:magic" }), "Window to scratchpad")

-- ── monitors ────────────────────────────────────────────────────────────────
bind(mod .. " + comma",          hl.dsp.focus({ monitor = -1 }), "Focus previous monitor")
bind(mod .. " + period",         hl.dsp.focus({ monitor =  1 }), "Focus next monitor")
bind(mod .. " + SHIFT + comma",  hl.dsp.workspace.move({ monitor = -1 }), "Workspace to previous monitor")
bind(mod .. " + SHIFT + period", hl.dsp.workspace.move({ monitor =  1 }), "Workspace to next monitor")

-- ── grouping (tabbed windows) ───────────────────────────────────────────────
bind(mod .. " + G",         hl.dsp.group.toggle(), "Toggle group (tabs)")
bind(mod .. " + SHIFT + G", hl.dsp.window.move({ out_of_group = true }), "Move out of group")
bind("ALT + bracketleft",   hl.dsp.group.prev(), "Previous tab in group")
bind("ALT + bracketright",  hl.dsp.group.next(), "Next tab in group")

-- ── screenshots ─────────────────────────────────────────────────────────────
bind(mod .. " + SHIFT + S", hl.dsp.exec_cmd([[grim -g "$(slurp -d)" - | swappy -f -]]), "Screenshot region")
bind("Print", hl.dsp.exec_cmd([[grim -g "$(slurp -d)" - | wl-copy]]), "Screenshot region to clipboard")
bind("SHIFT + Print", hl.dsp.exec_cmd(
    [[grim -o "$(hyprctl activeworkspace -j | jq -r .monitor)" ~/Pictures/Screenshots/$(date +%Y-%m-%d_%H-%M-%S).png]]),
    "Screenshot monitor to file")

-- Colour picker — copies the hex to the clipboard.
bind(mod .. " + SHIFT + C", hl.dsp.exec_cmd("hyprpicker -a"), "Colour picker")

-- ── clipboard ───────────────────────────────────────────────────────────────
-- Mac-style copy and paste. Hyprland grabs these before the focused app sees
-- them, so the script forwards the shortcut that app understands: Ctrl+Shift+C/V
-- in a terminal, where Ctrl+C is SIGINT, and Ctrl+C/V elsewhere.
bind(mod .. " + C", hl.dsp.exec_cmd("~/.config/hypr/scripts/clipboard.sh copy"),  "Copy")
bind(mod .. " + V", hl.dsp.exec_cmd("~/.config/hypr/scripts/clipboard.sh paste"), "Paste")

bind(mod .. " + X", hl.dsp.exec_cmd(
    [[cliphist list | wofi --dmenu --width 700 --height 400 | cliphist decode | wl-copy]]),
    "Clipboard history")

-- ── session ─────────────────────────────────────────────────────────────────
bind(mod .. " + Escape",    hl.dsp.exec_cmd("hyprlock"), "Lock screen")
bind(mod .. " + SHIFT + E", hl.dsp.exec_cmd("~/.config/hypr/scripts/powermenu.sh"), "Power menu")
bind(mod .. " + slash",     hl.dsp.exec_cmd("~/.config/hypr/scripts/keybinds.sh"), "This cheatsheet")
bind(mod .. " + W",         hl.dsp.exec_cmd("~/.config/hypr/scripts/wallpaper.sh"), "Wallpaper picker")
bind(mod .. " + SHIFT + T", hl.dsp.exec_cmd("~/.config/hypr/scripts/theme.sh"), "Colour theme picker")
bind(mod .. " + SHIFT + R", hl.dsp.exec_cmd("killall -SIGUSR2 waybar"), "Reload waybar")

-- ── media and hardware keys ─────────────────────────────────────────────────
-- locked = still works on the lock screen. repeating = fires while held.
local osd = { locked = true, repeating = true }
bind("XF86AudioRaiseVolume",  hl.dsp.exec_cmd("swayosd-client --output-volume raise"), "AudioRaiseVolume", osd)
bind("XF86AudioLowerVolume",  hl.dsp.exec_cmd("swayosd-client --output-volume lower"), "AudioLowerVolume", osd)
hl.bind("XF86MonBrightnessUp",   hl.dsp.exec_cmd("swayosd-client --brightness raise"),    osd)
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("swayosd-client --brightness lower"),    osd)

local lockedOnly = { locked = true }
bind("XF86AudioMute",    hl.dsp.exec_cmd("swayosd-client --output-volume mute-toggle"), "AudioMute", lockedOnly)
hl.bind("XF86AudioMicMute", hl.dsp.exec_cmd("swayosd-client --input-volume mute-toggle"),  lockedOnly)
bind("XF86AudioPlay",    hl.dsp.exec_cmd("playerctl play-pause"), "AudioPlay", lockedOnly)
bind("XF86AudioPause",   hl.dsp.exec_cmd("playerctl play-pause"), "AudioPause", lockedOnly)
hl.bind("XF86AudioNext",    hl.dsp.exec_cmd("playerctl next"),       lockedOnly)
hl.bind("XF86AudioPrev",    hl.dsp.exec_cmd("playerctl previous"),   lockedOnly)

-- ── submaps ─────────────────────────────────────────────────────────────────
-- A "resize mode": press SUPER+R, resize with hjkl or the arrows, Escape leaves.
hl.define_submap("resize", function()
    local steps = {
        h = { x = -40, y =   0 }, l = { x = 40, y =   0 },
        k = { x =   0, y = -40 }, j = { x =  0, y =  40 },
        left = { x = -40, y = 0 }, right = { x = 40, y =  0 },
        up   = { x = 0, y = -40 }, down  = { x =  0, y = 40 },
    }
    for key, d in pairs(steps) do
        hl.bind(key, hl.dsp.window.resize({ x = d.x, y = d.y, relative = true }),
            { repeating = true, description = "Resize " .. key })
    end
    hl.bind("escape", hl.dsp.submap("reset"), { description = "Leave resize mode" })
    hl.bind("Return", hl.dsp.submap("reset"), { description = "Leave resize mode" })
end)

bind(mod .. " + R", hl.dsp.submap("resize"), "Resize mode (hjkl, Esc exits)")
