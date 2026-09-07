# hyprland-setup

Turns a fresh Arch Linux install into a working Hyprland desktop, and keeps the
result editable rather than magic.

```bash
git clone <this repo> ~/hyprland-setup   # or copy the folder over
cd ~/hyprland-setup
./install.sh
sudo reboot
```

Re-running is safe and cheap — see **Re-running** below.

## Re-running

The script is meant to be run again whenever you change something in
`config/`. On a second run it works out that packages and services are
already in place and becomes a fast config sync:

```
==> Assessing current state
    packages:  0 of 105 missing
    services:  0 pending
    ✓ system already provisioned — this run only refreshes configs

==> Syncing configuration files
    updated  hypr/theme.conf
    ✓ 0 added, 1 updated, 19 unchanged
```

It compares file by file, so:

- identical files are not touched at all — verified down to mtime: three
  consecutive runs leave every file's timestamp, size and mode unchanged
  and create no backup directory
- only files that actually changed are backed up, into
  `~/.config-backup-<timestamp>/` with their paths preserved
- files that exist only in `~/.config` are never deleted
- **`monitors.conf` is left alone**, so a hand-tuned display layout
  survives a re-run (`--redetect-monitors` rebuilds it)
- sudo is only requested if something genuinely needs root
- `gpu.conf` carries no timestamp on purpose: its content is a pure function of
  the detected hardware, so it is rewritten only when the GPU actually changes

Use `--dry-run` to see what would change without writing anything.

## Options

| Flag | Effect |
| --- | --- |
| `--configs-only` | Never touch packages or services |
| `--packages-only` | Never touch dotfiles |
| `--force-packages` | Re-run the package and service steps even if complete |
| `--redetect-monitors` | Regenerate `monitors.conf` from connected displays |
| `--dry-run` | Show what would change; write nothing |
| `--aur` | Also build `paru`, an AUR helper (off by default) |
| `--no-gaming` | Skip multilib, Steam, gamemode, 32-bit drivers |
| `--no-bluetooth` | Skip `bluez` / `blueman` |
| `--no-greetd` | No login manager — start Hyprland from a TTY |

## Graphics drivers

The script reads the PCI vendor ID from `/sys/class/drm/card*/device/vendor`
(no `lspci` dependency) and installs the matching stack:

| Detected | 64-bit | 32-bit (gaming) |
| --- | --- | --- |
| AMD | `vulkan-radeon` | `lib32-vulkan-radeon` |
| Intel | `vulkan-intel`, `intel-media-driver` | `lib32-vulkan-intel` |
| NVIDIA | `nvidia-open-dkms`, `nvidia-utils`, `egl-wayland`, `libva-nvidia-driver`, kernel headers | `lib32-nvidia-utils` |
| VM | `vulkan-virtio`, `vulkan-swrast` | — |
| Unknown | `vulkan-swrast` (software) | — |

Hybrid systems (Intel iGPU + NVIDIA dGPU) get both, plus a note in
`gpu.conf` about `AQ_DRM_DEVICES` for choosing the render GPU.

The matching environment variables are written to a generated
`~/.config/hypr/gpu.conf` — `AMD_VULKAN_ICD`/`radeonsi` for AMD, `iHD` for
Intel, `__GLX_VENDOR_LIBRARY_NAME`/`NVD_BACKEND` for NVIDIA. Nothing
vendor-specific is hardcoded in the shipped configs.

> **NVIDIA caveat:** `nvidia-open-dkms` covers Turing and newer (RTX 20xx /
> GTX 16xx up). Driver 590 dropped Maxwell and Pascal, so GTX 9xx/10xx need
> `nvidia-580xx-dkms` from the AUR — the script detects NVIDIA and prints
> this rather than guessing. Early KMS is deliberately *not* configured
> automatically, since it can break resume-from-hibernation.

## What it installs

| Role | Package |
| --- | --- |
| Compositor | `hyprland` (launched through `uwsm`) |
| Login | `greetd` + `tuigreet` |
| Bar | `waybar` |
| Launcher | `wofi` |
| Notifications | `mako` |
| Terminal | `kitty` |
| Browser | `firefox` |
| Editors | `neovim`, `vim` |
| Files | `thunar` + `gvfs` + `udiskie` |
| Lock / idle / wallpaper | `hyprlock`, `hypridle`, `hyprpaper` |
| Audio | PipeWire + WirePlumber |
| GPU | Mesa + the driver for your detected card (see above) |
| Screenshots | `grim` + `slurp` + `swappy` |
| Clipboard | `wl-clipboard` + `cliphist` |
| OSD | `swayosd` (volume / brightness popups) |

## Layout

```
config/hypr/
  hyprland.conf    variables + sources everything else
  monitors.conf    GENERATED at install time from your connected displays
  env.conf         environment variables
  theme.conf       colours, gaps, borders, blur, animations
  input.conf       keyboard, mouse, touchpad, gestures
  keybinds.conf    every shortcut
  rules.conf       window / layer / workspace rules
  autostart.conf   what launches at login
  hyprlock.conf    lock screen
  hypridle.conf    idle timeouts
  hyprpaper.conf   wallpaper
  scripts/         power menu, keybind cheatsheet
```

Hyprland reloads on save — no restart needed.

## Keys

`SUPER + /` shows a live cheatsheet in wofi, read straight from the running
compositor via `hyprctl binds` — so it can never drift out of sync with
`keybinds.conf`. It groups submap binds separately, since those only work
inside that mode.

For a terminal dump instead of the popup:

```bash
~/.config/hypr/scripts/keybinds.sh --print
```

Or straight from Hyprland: `hyprctl binds` (raw), `hyprctl -j binds` (JSON).

| Key | Action |
| --- | --- |
| `SUPER + Return` | Terminal |
| `SUPER + D` | App launcher |
| `SUPER + E` | File manager |
| `SUPER + B` | Browser (firefox) |
| `SUPER + N` | Editor (nvim in kitty) |
| `SUPER + Q` | Close window |
| `SUPER + F` | Fullscreen |
| `SUPER + CTRL + V` | Toggle floating |
| `SUPER + CTRL + C` | Centre window |
| `SUPER + C` / `SUPER + V` | Copy / paste (Mac-style) |
| `SUPER + 1..0` | Switch workspace |
| `SUPER + SHIFT + 1..0` | Move window to workspace |
| `SUPER + Tab` / `SUPER + SHIFT + Tab` | Next / previous workspace (wraps) |
| `SUPER + T` | Toggle dwindle ⇄ scrolling layout |
| `SUPER + -` / `SUPER + =` | Scrolling: narrower / wider column |
| `SUPER + S` | Scratchpad |
| `SUPER + R` | Resize mode (`hjkl`, Escape to exit) |
| `SUPER + X` | Clipboard history |
| `SUPER + SHIFT + S` | Screenshot region → annotate |
| `SUPER + Escape` | Lock |
| `SUPER + SHIFT + E` | Power menu |
| `SUPER + SHIFT + M` | Exit Hyprland |

## Notes

- **Config syntax targets Hyprland 0.56+.** The window-rule syntax changed in
  0.56 (`windowrulev2` is now a hard error) and gestures changed in 0.51.
  `rules.conf` and `input.conf` use the current forms.
- **Default scale is 1.6** (`DEFAULT_SCALE` at the top of `install.sh`). A scale
  is only applied where `RESOLUTION / SCALE` is a whole number, which Hyprland
  requires; on a display it does not divide (1366x768, 1600x900) the script
  falls back to scale 1 for that monitor and says so.
- **Two tiling layouts.** `theme.conf` sets `general:layout` (dwindle by
  default) and `SUPER + T` flips the running session between dwindle and
  Hyprland's built-in scrolling layout — a PaperWM-style tape of columns.
  Scrolling needs no plugin as of 0.56. The toggle is a runtime
  `hyprctl keyword`, so `hyprctl reload` or a new session returns to the
  `theme.conf` default; change that line to start in scrolling instead.
  `SUPER + ALT + ...` binds drive the tape and do nothing under dwindle.
- **`hyprctl dispatch` speaks Lua here, and that breaks other people's tools.**
  With a Lua config Hyprland evaluates everything after `dispatch` as Lua, so
  `hyprctl dispatch workspace 3` is a syntax error, not a workspace switch —
  and a failed dispatch is silent. Every call in this repo uses the Lua form
  (`hyprctl dispatch 'hl.dsp.focus({ workspace = 3 })'`); `hyprctl repl` will
  show you what is available under `hl.dsp`. The catch is third-party programs
  that send the old strings and cannot be told otherwise. Waybar's
  `hyprland/workspaces` is one, which is why the bar draws its workspace row
  out of ten custom modules instead — see `waybar/config.jsonc`. Anything else
  you add that "does nothing when clicked" is worth checking here first.
- **Mac-style copy and paste.** `SUPER + C` and `SUPER + V` are bound to
  `clipboard.sh`, which looks at the focused window's class and forwards the
  shortcut that application actually understands: `Ctrl+Shift+C/V` in a
  terminal, where `Ctrl+C` is SIGINT, and `Ctrl+C/V` everywhere else. Hyprland
  grabs the keys before the app sees them, so the forwarding is what makes it
  work at all. The window actions that used to sit on those keys moved to
  `SUPER + CTRL + C` and `SUPER + CTRL + V`. A terminal launched with a custom
  `--class` will not be recognised; add it to `TERMINALS` in the script.
- **`monitors.conf` is generated**, not shipped, so the layout matches the
  machine you install on. Re-run the installer after changing monitors, or use
  `nwg-displays` for a GUI.
- **Not every window-rule effect is a boolean.** `idle_inhibit` takes a mode
  (`none| always | focus | fullscreen`), `opacity` takes 1-2 floats, and
  `size`/`move` take a vec2. Writing `idle_inhibit true` is a parse error.
- **Check for mistakes** after editing with `hyprctl configerrors`.
- **Locked out?** `Ctrl + Alt + F2` gets you a TTY.
