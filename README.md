# hyprland-setup

Turns a fresh Arch Linux or Fedora install into a working Hyprland desktop, and
keeps the result editable rather than magic. Fedora includes aarch64 — Fedora
Asahi Remix on Apple silicon is the tested case.

## On a new machine

Start from a fresh Arch install with a network connection and an ordinary user
account in `wheel`. Run it as that user, not as root — it calls `sudo` itself,
for the few steps that need it.

```bash
sudo pacman -S --needed git
git clone https://github.com/paulbeavers/hyprland-setup.git ~/hyprland-setup
cd ~/hyprland-setup
./install.sh
sudo reboot
```

That installs the packages, enables the services, writes the config into
`~/.config`, detects the displays and the GPU, and installs `starch-config`.
It takes a while on a cold pacman cache, and asks for your password once.

`--dry-run` shows what it would do and writes nothing. Re-running afterwards is
safe and cheap — see **Re-running** below.

If you would rather not build a machine by hand, the [starch](https://github.com/paulbeavers/starch)
ISO installs all of this and then removes itself, leaving a plain Arch system
with this desktop on it.

## On Fedora

Fedora 41 or later (the script uses dnf5), any edition, x86_64 or aarch64 —
including Fedora Asahi Remix on Apple silicon. The steps are the same:

```bash
sudo dnf install git
git clone https://github.com/paulbeavers/hyprland-setup.git ~/hyprland-setup
cd ~/hyprland-setup
./install.sh
```

What differs from Arch:

- **Hyprland comes from a COPR.** Fedora does not package it. If a Hyprland
  is already installed, or an enabled repository already offers one, that is
  what gets used. Only when nothing does is the
  [`nett00n/hyprland`](https://copr.fedorainfracloud.org/coprs/nett00n/hyprland/)
  COPR enabled. It also supplies `uwsm`, `hyprpolkitagent`, `swayosd`,
  `cliphist` and a current `waybar`. The config is Lua, so Hyprland has to be
  0.55 or newer, and the script warns if it is not.
- **Your login screen stays.** Fedora Workstation already has GDM, which lists
  Hyprland's sessions by itself, so greetd is not installed. Pick
  **Hyprland (uwsm-managed)** from the session menu. `--greetd` replaces GDM
  with greetd + tuigreet instead, as on Arch.
- **Nerd Fonts are downloaded.** Fedora does not package JetBrainsMono Nerd
  Font or the Nerd Font symbols, so they come from the upstream release into
  `/usr/local/share/fonts/nerd-fonts`.
- **No full system upgrade.** Arch runs `pacman -Syu` before installing
  anything, because it does not support partial upgrades. Fedora does, so the
  script only runs `dnf install`.
- **Not packaged, so not installed:** `nwg-look` and `nwg-displays`
  (`starch-config` covers displays), and `starship`, which nothing here uses.
  Anything no enabled repository offers on this machine, such as Steam away
  from Asahi or the Intel iHD driver without RPM Fusion, is reported and
  skipped.
- **NVIDIA and Broadcom `wl`** drivers live in RPM Fusion. The script says so
  rather than enabling a third-party repository for you.

On Apple silicon the GPU is recognised from its kernel driver (`asahi`) rather
than a PCI ID, and needs no environment variables: Mesa's asahi and Honeykrisp
drivers are picked up on their own.

## What it does not touch

The boot. On either distro, `install.sh` leaves Plymouth, the initramfs and the
kernel command line as it found them — a desktop has no business rebuilding
them. The starch boot splash belongs to
[starch](https://github.com/paulbeavers/starch), which puts it on the machines
it installs.

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
    updated  hypr/theme.lua
    ✓ 0 added, 1 updated, 19 unchanged
```

It compares file by file, so:

- identical files are not touched at all — verified down to mtime: three
  consecutive runs leave every file's timestamp, size and mode unchanged
  and create no backup directory
- only files that actually changed are backed up, into
  `~/.config-backup-<timestamp>/` with their paths preserved
- files that exist only in `~/.config` are never deleted
- **`monitors.lua` is left alone**, so a hand-tuned display layout
  survives a re-run (`--redetect-monitors` rebuilds it)
- sudo is only requested if something genuinely needs root
- `gpu.lua` carries no timestamp on purpose: its content is a pure function of
  the detected hardware, so it is rewritten only when the GPU actually changes

Use `--dry-run` to see what would change without writing anything.

## Options

| Flag | Effect |
| --- | --- |
| `--configs-only` | Never touch packages or services |
| `--packages-only` | Never touch dotfiles |
| `--force-packages` | Re-run the package and service steps even if complete |
| `--redetect-monitors` | Regenerate `monitors.lua` from connected displays |
| `--dry-run` | Show what would change; write nothing |
| `--aur` | Arch only. Also build `paru`, an AUR helper (off by default) |
| `--gaming` | Also install Steam, gamemode, mangohud; on Arch, multilib and 32-bit drivers too |
| `--no-bluetooth` | Skip `bluez` / `blueman` |
| `--greetd` | Use greetd even if another display manager (GDM) is enabled, disabling it |
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

That table is Arch. On Fedora one package, `mesa-vulkan-drivers`, carries every
Mesa Vulkan driver, so the vendor adds little. ARM GPUs have no PCI ID and are
recognised by kernel driver instead: `asahi` (Apple silicon), and `panfrost`,
`panthor`, `msm`, `v3d` and the like (other SoCs). Display-only devices such
as `apple-drm` are not counted as GPUs.

Hybrid systems (Intel iGPU + NVIDIA dGPU) get both, plus a note in
`gpu.lua` about `AQ_DRM_DEVICES` for choosing the render GPU.

The matching environment variables are written to a generated
`~/.config/hypr/gpu.lua` — `AMD_VULKAN_ICD`/`radeonsi` for AMD, `iHD` for
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

The Hyprland configuration is Lua. 0.55 deprecated the hyprlang `.conf`
format and 0.57 removes it; the files that are still `.conf` below belong to
other programs, which have their own formats.

```
config/hypr/
  hyprland.lua     requires everything else, in order
  env.lua          environment variables
  theme.lua        gaps, borders, blur, animations
  input.lua        keyboard, mouse, touchpad, gestures
  keybinds.lua     every shortcut
  rules.lua        window / layer / workspace rules
  autostart.lua    what launches at login
  programs.lua     which terminal, browser, editor and launcher to use
  themes/          the palettes SUPER+SHIFT+T switches between
  scripts/         theme, wallpaper, power menu, cheatsheet, clipboard,
                   layout toggle, keyboard backlight

  hyprlock.conf    lock screen        (hyprlock's own format)
  hypridle.conf    idle timeouts      (hypridle's own format)
  hyprpaper.conf   wallpaper          (hyprpaper's own format)

generated, never shipped:
  monitors.lua     written at install time from your connected displays
  gpu.lua          written from the card that was detected
  colors.lua       written by scripts/theme.sh from the active palette
  settings.lua     written by starch-config; loaded last, so it wins
```

Hyprland reloads on save — no restart needed. Check a change with
`hyprctl configerrors`, or before logging in with
`Hyprland --verify-config`.

## Keys

`SUPER + /` shows a live cheatsheet in wofi, read straight from the running
compositor via `hyprctl binds` — so it can never drift out of sync with
`keybinds.lua`. It groups submap binds separately, since those only work
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
| `SUPER + I` | Settings (starch-config) |
| `SUPER + Escape` | Lock |
| `SUPER + SHIFT + E` | Power menu |
| `SUPER + SHIFT + M` | Exit Hyprland |

## Notes

- **Config syntax targets Hyprland 0.56+.** The window-rule syntax changed in
  0.56 (`windowrulev2` is now a hard error) and gestures changed in 0.51.
  `rules.lua` and `input.lua` use the current forms.
- **Default scale is 1.6** (`DEFAULT_SCALE` at the top of `install.sh`). A scale
  is only applied where `RESOLUTION / SCALE` is a whole number, which Hyprland
  requires; on a display it does not divide (1366x768, 1600x900) the script
  falls back to scale 1 for that monitor and says so.
- **One accent colour, named once.** The focused border, the active workspace,
  the selected launcher row, a checked switch and the lock ring all use
  `accent`, which `theme.sh` derives from the active palette — the theme's own
  `sapphire` unless the `.theme` file names another role, e.g. `accent = teal`.
  Changing what the desktop highlights with is one line, not a dozen edits
  across five config formats.
- **Two tiling layouts.** `theme.lua` sets `general:layout` (dwindle by
  default) and `SUPER + T` flips the running session between dwindle and
  Hyprland's built-in scrolling layout — a PaperWM-style tape of columns.
  Scrolling needs no plugin as of 0.56. The toggle is a runtime
  `hyprctl keyword`, so `hyprctl reload` or a new session returns to the
  `theme.lua` default; change that line to start in scrolling instead.
  `SUPER + ALT + ...` binds drive the tape and do nothing under dwindle.
- **`starch-config` is the settings app.** `SUPER + I`, or "Settings" in the
  launcher. It also opens on its welcome page at first login, and that page
  has a switch to stop it doing so. It covers display scale, resolution and refresh; the idle timeouts
  and the lid; keyboard and touchpad; theme, wallpaper, cursor and font. Two
  things worth knowing about it. It never edits a hand-written config: it owns
  `monitors.lua`, `hypridle.conf` and `settings.lua` outright and rewrites them
  whole, keeping the previous version as `.bak`, and `settings.lua` is loaded
  last by `hyprland.lua` so it overrides `input.lua` without either file having
  to know about the other — delete it to go back to the defaults. And the scale
  menu offers only scales that are legal for the mode: Hyprland accepts any
  number and then silently snaps to one that divides the resolution into whole
  pixels, so a config can say 1.5 while the session runs at 1.6.
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
- **`monitors.lua` is generated**, not shipped, so the layout matches the
  machine you install on. Re-run the installer after changing monitors, or use
  `nwg-displays` for a GUI.
- **Not every window-rule effect is a boolean.** `idle_inhibit` takes a mode
  (`none| always | focus | fullscreen`), `opacity` takes 1-2 floats, and
  `size`/`move` take a vec2. Writing `idle_inhibit true` is a parse error.
- **Check for mistakes** after editing with `hyprctl configerrors`.
- **Locked out?** `Ctrl + Alt + F2` gets you a TTY.
