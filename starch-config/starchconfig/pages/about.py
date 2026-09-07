"""About — versions, and where everything this app writes actually lives.

The second half matters more than the first. Every other page ends by saying
"applying rewrites such-and-such a file"; this is the one place that lists them
together, so it is possible to see at a glance what starch-config owns and what
it will never touch.
"""

import platform
import subprocess

from .. import __version__, hypr, paths, readback
from ..widgets import Page, Row
from gi.repository import Gtk


def _version(command, args=("--version",)):
    try:
        out = subprocess.run(
            [command, *args], capture_output=True, text=True, timeout=5
        )
    except (OSError, subprocess.TimeoutExpired):
        return "not installed"
    text = (out.stdout or out.stderr).strip().splitlines()
    return text[0] if text else "unknown"


def _value(text, dim=False):
    label = Gtk.Label(label=text, xalign=1.0)
    label.add_css_class("sc-dim" if dim else "sc-row-title")
    label.set_selectable(True)
    return label


def build(window):
    page = Page("About", "What this is, and what it writes.")

    card = page.section("Versions")
    card.add(Row("starch-config", _value(__version__)))
    card.add(Row("Hyprland", _value(_hyprland_version())))
    card.add(Row("Waybar", _value(_version("waybar"))))
    card.add(Row("GTK", _value("%d.%d.%d" % (
        Gtk.get_major_version(), Gtk.get_minor_version(), Gtk.get_micro_version()))))
    card.add(Row("Kernel", _value(platform.release())))

    card = page.section("Files it writes")
    card.add(Row("Display", _value(_short(paths.MONITORS_LUA), dim=True),
                 "Rewritten whole. Previous version kept as .bak."))
    card.add(Row("Idle", _value(_short(paths.HYPRIDLE_CONF), dim=True),
                 "Rewritten whole. Previous version kept as .bak."))
    card.add(Row("Input", _value(_short(paths.SETTINGS_LUA), dim=True),
                 "Loaded after the hand-written config, so it wins. Delete it "
                 "to go back to the defaults."))
    card.add(Row("Lid", _value(str(readback.LID_CONF), dim=True),
                 "The only file outside your home directory. Needs a password."))

    card = page.section("Files it never touches")
    for name in ("input.lua", "theme.lua", "keybinds.lua", "rules.lua",
                 "autostart.lua", "env.lua"):
        card.add(Row(name, _value("hand-written", dim=True)))

    page.note(
        "Theme and wallpaper are not in either list: those are applied by "
        "hypr/scripts/theme.sh and wallpaper.sh, which this app calls rather "
        "than duplicates."
    )
    return page


def _short(path):
    try:
        return "~/" + str(path.relative_to(paths.HOME))
    except ValueError:
        return str(path)


def _hyprland_version():
    if not hypr.available():
        return "not running"
    try:
        first = hypr._run(["version"]).strip().splitlines()[0]
    except Exception:
        return "unknown"
    return first.replace("Hyprland ", "").split(" built")[0]
