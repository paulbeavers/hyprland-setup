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
