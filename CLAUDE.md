# Working on hyprland-setup

The desktop half of [starch](https://github.com/paulbeavers/starch): a script
that turns a fresh Arch install into a Hyprland desktop, the configuration it
deploys, and `starch-config`. `README.md` is written for someone using it; this
file is for someone changing it.

## The configuration is Lua, and that has consequences

Hyprland 0.55 deprecated the hyprlang `.conf` format and 0.57 removes it.
`config/hypr/*.lua` is the current form. The files still ending in `.conf` —
`hyprlock`, `hypridle`, `hyprpaper` — belong to other programs and keep their
own formats.

**`hyprctl dispatch` now takes Lua, and the old syntax fails silently.** With a
Lua config Hyprland wraps everything after `dispatch` in `return
hl.dispatch(...)` and evaluates it, so `hyprctl dispatch dpms off` is a syntax
error. The legacy translator is still in the binary but nothing on the IPC path
can reach it, and the error goes back to the caller, which throws it away. This
had quietly broken screen blanking, log out, `SUPER+C/V` and the workspace row
in the bar. Every call in this repo uses the Lua form:

    hyprctl dispatch 'hl.dsp.focus({ workspace = 3 })'

`hyprctl repl` lists what is under `hl.dsp`. Watch for arguments that are
accepted but wrong: `hl.dsp.dpms("off")` is not an error, it silently means
*toggle*. The table form `{ action = "off" }` is what you want.

**Third-party tools that send the old strings cannot be fixed from here.**
Waybar's `hyprland/workspaces` hardcodes `dispatch workspace N` with no setting
to change it, which is why the bar draws its workspace row from ten `custom/`
modules instead. Anything new that "does nothing when clicked" is worth
checking here first.

**`hl.config` sets one key and leaves its siblings alone.** That is what makes
`settings.lua` safe: `hyprland.lua` loads it last, so `starch-config` can
override four input settings without rewriting `input.lua`.

Check a change with `Hyprland --verify-config -c config/hypr/hyprland.lua`,
which needs no running compositor, or `hyprctl configerrors` in a session.

## install.sh

**Two distros, one desktop.** `DISTRO` (arch | fedora, from `/etc/os-release`)
selects the package lists, the package manager, the greeter account and where
Hyprland comes from. Everything under `config/` is shared and must stay
distro-neutral. A package added to one list needs its counterpart in the other;
Fedora names differ often (`python3-gobject`, `Thunar`, `qt6-qtwayland`), and
`dnf repoquery <name>` on a Fedora box says whether one exists. Fedora has no
Hyprland of its own: an installed build or an enabled COPR is always respected,
and `nett00n/hyprland` is enabled only when nothing provides it.

**It does not touch the boot.** No Plymouth, initramfs or kernel command line:
the splash lives in starch, which owns the machines it installs. It used to live
here, and on Fedora that meant a desktop install replacing the distro's boot
theme and rebuilding every initramfs.

**starch reads the package lists out of this file.** Its `extract-packages.sh`
takes `^PKGS_...=(` through `^)` with sed, so the Arch arrays must stay at
column 0, and anything between them — the sed range runs past one-line arrays
to the next column-0 `)` — is evaluated there with `set -u` and no `DISTRO`.

Idempotent by design: a second run detects that packages and services are in
place and becomes a config sync. It backs up only files that actually changed.
`monitors.lua` is left alone once written, so a hand-tuned layout survives.

**Anything `*.sh` under `config/` is chmod 755 on deploy**, deliberately:
install media strips modes, so without it every keybind that runs a script is a
silent no-op. A new script that is not `*.sh` will not get the bit.

## starch-config

GTK4 through PyGObject, **deliberately without libadwaita** — it encodes
GNOME's design language and resists being overridden.

- **`sidebar`, `titlebar` and `card` are built-in GTK style classes** with
  their own backgrounds and `:backdrop` variants. Styling them is arguing with
  Adwaita, and Adwaita's more specific selectors win. Every class here is
  namespaced `sc-`. Suspect this first for "my CSS is being ignored".
- **Translucency is not symmetric.** A dark `@base` at 60% over a wallpaper
  still reads dark; a light one turns grey and swallows its own dark text.
  `theme.py` decides light-vs-dark from `@base` luminance and the stylesheet
  carries two sets of alphas. Test any visual change against Catppuccin Latte.
- It is themed from `waybar/colors.css`, the palette `theme.sh` already
  renders, watched via a monitor on the *directory* — `theme.sh` moves a temp
  file into place, so a watch on the old inode goes deaf after one switch.
- It never edits a hand-written config. It owns `monitors.lua`,
  `hypridle.conf` and `settings.lua`, rewrites them whole and keeps a `.bak`.

Display scale is the setting worth understanding: a scale is legal only if it
is a multiple of 1/120 *and* divides the resolution into whole pixels both
ways. Hyprland accepts anything and then silently snaps, so a config can say
1.5 while the session runs at 1.6. `scales.py` enumerates the legal ones.

## Two traps that cost a day each

**kitty remembers being maximized, and asks for it again.** Every terminal on
an installed system came up covering the screen with the tiled windows behind
it — only kitty, only installs, never the live medium. It was not a window
rule. kitty defaults `remember_window_size` to yes: it records the OS window's
size *and maximize state* in `~/.cache/kitty/main.json` and asks the compositor
for the same again on every new window. `SUPER+SHIFT+F` fixed the window on
screen and the next one came back maximized, because the cache still said so.
`kitty.conf` now sets `remember_window_size no`; under a tiling compositor the
geometry is the tiler's decision. It never showed on the medium because the
live user's home is a fresh overlay each boot, so the cache never survived to
be read — which is the shape of every "installs but not live" bug here.

**Never kill a hyprpaper that is running.** `autostart.lua` starts hyprpaper
and calls `wallpaper.sh --restore` in the same breath, so the first IPC
attempts land before its socket exists. The old fallback waited one second,
then killed hyprpaper and restarted it. When a second caller was added to "fix"
the missing wallpaper, the two ran concurrently and each destroyed the daemon
the other was waiting for; `/tmp/wallpaper.log` showed two "did not answer in
10s" entries seven seconds apart, which one caller cannot produce. It now
starts hyprpaper only if none is running and waits twenty seconds.

`wallpaper.sh` writes a line to `/tmp/wallpaper.log` on the way through. Keep
it: `hyprctl hyprpaper wallpaper` answers "ok" whether or not hyprpaper has a
surface to paint on, and 0.8.4 has no verb to ask what it is showing, so the
reply proves nothing and the log is the only record of what was attempted.

## Broadcom: check the kernel's table, not a datasheet

`WL_IDS` in `install.sh` and `installer/broadcom-live` is the list of cards the
in-kernel drivers *cannot* drive. Two were wrong — 43ba (BCM43602) and 43a3
(BCM4350) — and brcmfmac claims both outright and ships their firmware, so
listing them blacklisted the driver that works and loaded `wl`, which cannot
bind them. A 2013 15" MacBook Pro had no wireless at all as a result. Before
adding an id:

    modinfo brcmfmac | grep -oiE 'd0000[0-9A-F]{4}'

If brcmfmac claims it, `wl` is the wrong answer. And `wl` matches on PCI
*class*, not device id, so it is autoloaded for cards it cannot drive and
races the right driver — which is why a card that is not on the list now gets
`blacklist wl` written for it rather than nothing.

## Do not run sudo from a tool call

There is no TTY, so sudo cannot prompt, and PAM counts each failure. With
`deny=3` three calls in one chain lock the user out of sudo for ten minutes.
Hand them the command — `./install.sh --configs-only` makes nine sudo calls.
