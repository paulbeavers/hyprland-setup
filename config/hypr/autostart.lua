--------------------------------------------------------------------------------
--  Autostart
--
--  The hyprlang `exec-once` became an event handler: everything here runs once,
--  when the compositor finishes starting. There is no `exec` (run on reload)
--  equivalent, which is fine — nothing here wanted that.
--
--  uwsm-managed sessions start the portals and polkit agent as systemd user
--  units, so this stays short on purpose.
--------------------------------------------------------------------------------

hl.on("hyprland.start", function()
    -- Tell systemd and D-Bus about the session so portals, screen sharing and
    -- xdg-open all find the right compositor.
    hl.exec_cmd("dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP HYPRLAND_INSTANCE_SIGNATURE")

    -- Without a polkit agent anything asking for a password silently fails.
    hl.exec_cmd("systemctl --user start hyprpolkitagent")
    hl.exec_cmd("/usr/bin/gnome-keyring-daemon --start --components=secrets")

    -- Shell components.
    hl.exec_cmd("waybar")
    hl.exec_cmd("mako")
    hl.exec_cmd("hyprpaper")

    -- And then tell it what to show, rather than trusting it to read its own
    -- configuration. hyprpaper does not reliably apply hyprpaper.conf at
    -- startup — on some outputs it logs "Monitor <name> has no target: no wp
    -- will be created" and leaves the desktop bare, with the correct file
    -- named in the config it just read. Setting the same wallpaper over IPC
    -- works every time, and that is the path the picker already uses.
    --
    -- This is why a wallpaper chosen with SUPER+W would survive until the next
    -- reboot and then vanish: the picker applies over IPC and it appears; the
    -- config it also writes is what does not come back.
    --
    -- --restore reads the recorded choice and applies it. It is a no-op when
    -- nothing has been chosen, and it retries once if hyprpaper is not
    -- listening yet, so the ordering here does not have to be exact.
    hl.exec_cmd("~/.config/hypr/scripts/wallpaper.sh --restore")
    hl.exec_cmd("hypridle")
    hl.exec_cmd("swayosd-server")

    -- Tray applets.
    hl.exec_cmd("nm-applet --indicator")
    hl.exec_cmd("blueman-applet")
    hl.exec_cmd("udiskie --tray")

    -- cliphist watches the clipboard; SUPER+X browses it.
    hl.exec_cmd("wl-paste --type text  --watch cliphist store")
    hl.exec_cmd("wl-paste --type image --watch cliphist store")

    hl.exec_cmd("mkdir -p ~/Pictures/Screenshots")

    -- Set the cursor explicitly so XWayland apps do not fall back to X11's.
    hl.exec_cmd("hyprctl setcursor Adwaita 24")
end)

--------------------------------------------------------------------------------
--  Keep the workspace row in the bar current
--
--  The bar draws workspaces with ten custom modules instead of waybar's
--  hyprland/workspaces, because that module cannot switch workspaces on a
--  Lua-configured Hyprland — see waybar/config.jsonc for the whole story. A
--  custom module only refreshes when told to, and SIGRTMIN+1 is what tells it
--  (every one of the ten carries "signal": 1).
--
--  Doing it from here rather than from a daemon tailing the event socket means
--  no extra process, and no socat: the compositor already knows, so it can just
--  say so.
--------------------------------------------------------------------------------

local function refresh_workspaces()
    hl.exec_cmd("pkill -RTMIN+1 waybar")
end

for _, event in ipairs({
    "workspace.active",
    "workspace.created",
    "workspace.removed",
    "window.open",
    "window.close",
    "window.urgent",
    "monitor.focused",
}) do
    hl.on(event, refresh_workspaces)
end
