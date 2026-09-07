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

## Do not run sudo from a tool call

There is no TTY, so sudo cannot prompt, and PAM counts each failure. With
`deny=3` three calls in one chain lock the user out of sudo for ten minutes.
Hand them the command — `./install.sh --configs-only` makes nine sudo calls.
