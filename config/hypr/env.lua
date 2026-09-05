--------------------------------------------------------------------------------
--  Environment variables
--
--  Exported into the Hyprland session. Launched via uwsm these also reach
--  systemd user services, which is why the portals behave correctly.
--------------------------------------------------------------------------------

-- Toolkit backends: force native Wayland where it works, fall back to X11.
hl.env("GDK_BACKEND", "wayland,x11,*")
hl.env("SDL_VIDEODRIVER", "wayland")
hl.env("CLUTTER_BACKEND", "wayland")

-- Qt
hl.env("QT_QPA_PLATFORM", "wayland;xcb")
hl.env("QT_QPA_PLATFORMTHEME", "qt5ct")
hl.env("QT_WAYLAND_DISABLE_WINDOWDECORATION", "1")
hl.env("QT_AUTO_SCREEN_SCALE_FACTOR", "1")

-- XDG session identity. Portals and some apps key off these.
hl.env("XDG_CURRENT_DESKTOP", "Hyprland")
hl.env("XDG_SESSION_TYPE", "wayland")
hl.env("XDG_SESSION_DESKTOP", "Hyprland")

-- Cursor: XCURSOR_* for XWayland/GTK, hyprcursor for native surfaces.
hl.env("XCURSOR_THEME", "Adwaita")
hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_THEME", "Adwaita")
hl.env("HYPRCURSOR_SIZE", "24")

-- Vendor-specific GPU variables are NOT set here; the installer detects the
-- hardware and writes gpu.lua, which hyprland.lua requires.

hl.env("EDITOR", "nvim")
hl.env("VISUAL", "nvim")
hl.env("MOZ_ENABLE_WAYLAND", "1")

-- Many Electron apps still default to XWayland; this nudges newer ones over.
hl.env("ELECTRON_OZONE_PLATFORM_HINT", "auto")
hl.env("GTK_THEME", "Adwaita:dark")
