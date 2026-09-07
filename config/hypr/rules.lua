--------------------------------------------------------------------------------
--  Window, layer and workspace rules
--
--  hl.window_rule({ name, match = {...}, <effects> }). Every rule takes a name,
--  which is what a returned handle's :set_enabled(false) refers to — the old
--  syntax had no equivalent.
--
--  Match values are still regexes. Find a window's class/title with:
--      hyprctl clients
--------------------------------------------------------------------------------

local p = require("programs")

-- ── float the things that should float ──────────────────────────────────────
hl.window_rule({
    name  = "float-file-dialogs",
    match = { title = "^(Open File|Save File|Save As|Open Folder|Select a File)$" },
    float = true, center = true,
})

hl.window_rule({
    name  = "float-system-tools",
    match = { class = "^(pavucontrol|blueman-manager|nm-connection-editor)$" },
    float = true, size = { 900, 600 }, center = true,
})

hl.window_rule({
    name  = "float-calculator",
    match = { class = "^(org.gnome.Calculator|galculator)$" },
    float = true, size = { 400, 550 },
})

hl.window_rule({
    name  = "float-nwg",
    match = { class = "^(nwg-look|nwg-displays)$" },
    float = true, center = true,
})

hl.window_rule({
    name  = "float-thunar-progress",
    match = { class = "^(thunar)$", title = "^(File Operation Progress)$" },
    float = true, center = true,
})

hl.window_rule({
    name  = "float-portal",
    match = { class = "^(xdg-desktop-portal-gtk)$" },
    float = true, center = true,
})

hl.window_rule({
    name  = "float-media-viewers",
    match = { class = "^(imv|mpv)$" },
    float = true, size = { 1280, 720 }, center = true,
})

-- Picture-in-picture: float, pin above everything, park it bottom-right.
hl.window_rule({
    name  = "pip",
    match = { title = "^(Picture-in-Picture)$" },
    float = true, pin = true, size = { 640, 360 }, move = "100%-660 100%-420",
})

-- ── steam ───────────────────────────────────────────────────────────────────
hl.window_rule({
    name  = "steam-dialogs",
    match = { class = "^(steam)$", title = "^(Friends List|Steam Settings)$" },
    float = true, center = true,
})

hl.window_rule({
    name  = "steam-notifications",
    match = { class = "^(steam)$", title = "^()$" },
    no_focus = true,
})

-- ── games ───────────────────────────────────────────────────────────────────
-- `immediate` allows tearing, which cuts input latency in fullscreen games.
-- It only applies where general:allow_tearing is on (it is, in theme.lua).
hl.window_rule({
    name  = "game-tearing",
    match = { class = "^(steam_app_\\d+)$" },
    immediate = true, no_anim = true, idle_inhibit = "focus",
})

hl.window_rule({
    name  = "gamescope-tearing",
    match = { class = "^(gamescope)$" },
    immediate = true, no_anim = true, idle_inhibit = "focus",
})

-- Stop the screen blanking during fullscreen video or games. The mode is the
-- condition, so this matches everything.
hl.window_rule({
    name  = "idle-inhibit-fullscreen",
    match = { class = ".*" },
    idle_inhibit = "fullscreen",
})

-- ── transparency ────────────────────────────────────────────────────────────
-- Terminals and the file manager look good slightly see-through; keep it narrow.
hl.window_rule({ name = "opacity-kitty",  match = { class = "^(kitty)$" },  opacity = "0.94 0.88" })
hl.window_rule({ name = "opacity-thunar", match = { class = "^(thunar)$" }, opacity = "0.97 0.92" })

-- Never make video or images translucent — it ruins them.
hl.window_rule({ name = "opacity-media", match = { class = "^(mpv|imv)$" }, opacity = "1.0 1.0" })

-- ── privacy ─────────────────────────────────────────────────────────────────
-- Blank these out in screen shares rather than leaking them.
hl.window_rule({
    name  = "password-managers",
    match = { class = "^(1Password|Bitwarden|KeePassXC)$" },
    no_screen_share = true, float = true, center = true,
})

-- ── helper terminals ────────────────────────────────────────────────────────
-- Waybar's cpu/memory/network modules open btop and nmtui with this class.
hl.window_rule({
    name  = "floating-term",
    match = { class = "^(floating-term)$" },
    float = true, size = { 1100, 700 }, center = true,
})

-- The settings app. It draws its own title bar and its own rounded, part
-- transparent card, so Hyprland should neither decorate it nor round it a
-- second time — but it should blur what shows through, which is where the
-- frosted look comes from. Sized to the layout it was designed at.
hl.window_rule({
    name  = "starch-config",
    match = { class = "^(dev\\.starch\\.config)$" },
    float = true, size = { 880, 620 }, center = true,
    border_size = 0, rounding = 0, no_shadow = true,
})

-- ── layer rules ─────────────────────────────────────────────────────────────
-- Layers are the shell surfaces: the bar, the launcher, notifications.
hl.layer_rule({ name = "blur-waybar",  match = { namespace = "^(waybar)$" },        blur = true, ignore_alpha = 0.2 })
hl.layer_rule({ name = "blur-wofi",    match = { namespace = "^(wofi)$" },          blur = true, ignore_alpha = 0.3 })
hl.layer_rule({ name = "blur-notifs",  match = { namespace = "^(notifications)$" }, blur = true, ignore_alpha = 0.3 })
hl.layer_rule({ name = "no-anim-pick", match = { namespace = "^(hyprpicker)$" },    no_anim = true })

-- ── workspace rules ─────────────────────────────────────────────────────────
-- Workspaces 1-5 always exist, so the bar shows a stable row of numbers.
for i = 1, 5 do
    hl.workspace_rule({ workspace = tostring(i), persistent = true })
end

-- The scratchpad gets a bit of breathing room.
hl.workspace_rule({
    workspace        = "special:magic",
    on_created_empty = p.terminal,
    gaps_out         = 60,
})
