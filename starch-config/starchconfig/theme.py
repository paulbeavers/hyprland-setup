"""Load the stylesheet, with the live palette in front of it.

theme.sh already renders the active theme to waybar/colors.css as a list of
@define-color declarations. Rather than teach it about a third consumer, we
read that file and paste it on top of our own stylesheet — so the app is themed
by whatever the desktop is themed by, and SUPER+SHIFT+T changes both.
"""

import re
from pathlib import Path

from gi.repository import Gdk, Gio, Gtk

from . import paths

# Used when colors.css is missing, which is the case on live media and on any
# machine where theme.sh has not run yet. Catppuccin Mocha, the same default
# theme.sh ships with, so the app looks right rather than unstyled.
FALLBACK = """
@define-color crust     #11111b;
@define-color mantle    #181825;
@define-color base      #1e1e2e;
@define-color surface0  #313244;
@define-color surface1  #45475a;
@define-color overlay   #6c7086;
@define-color subtext   #a6adc8;
@define-color text      #cdd6f4;
@define-color rosewater #f5e0dc;
@define-color red       #f38ba8;
@define-color peach     #fab387;
@define-color yellow    #f9e2af;
@define-color green     #a6e3a1;
@define-color teal      #94e2d5;
@define-color sapphire  #74c7ec;
@define-color blue      #89b4fa;
@define-color lavender  #b4befe;
@define-color mauve     #cba6f7;
@define-color accent    #cba6f7;
@define-color pink      #f5c2e7;
"""


def palette_css() -> str:
    try:
        text = paths.COLORS_CSS.read_text()
    except OSError:
        return FALLBACK
    # A colors.css that somehow defines nothing would leave every colour
    # undefined and GTK would drop the rules that use them, so check.
    if "@define-color" not in text:
        return FALLBACK
    return text + _accent_fallback(text)


def _accent_fallback(palette: str) -> str:
    """Define @accent if the palette predates it.

    theme.sh grew an accent role, but a machine whose colors.css was rendered
    before that has no @accent — and GTK silently drops every rule naming a
    colour it does not know, which would strip the selection, the switches and
    the buttons rather than fail loudly. Fall back to the palette's own light
    blue, or to Catppuccin's if there is not one.
    """
    if re.search(r"@define-color\s+accent\b", palette):
        return ""
    match = re.search(r"@define-color\s+mauve\s+(#[0-9a-fA-F]{6})", palette)
    return "\n@define-color accent %s;\n" % (match.group(1) if match else "#cba6f7")


def _css() -> str:
    return palette_css() + "\n" + (Path(__file__).parent / "style.css").read_text()


def is_light(palette: str) -> bool:
    """Does this palette put dark text on a light background?

    It matters because translucency is not symmetric. A dark @base at 60% over
    a wallpaper still reads as dark, and light text stays legible. A light
    @base at 60% over the same wallpaper turns grey, and the dark text on it
    disappears — which is exactly how Catppuccin Latte broke twice. So the
    stylesheet carries both sets of alphas and the window gets a `light` class
    to pick between them.

    Decided from @base rather than a `mode` key because colors.css is the only
    file we read, and every palette has to define @base.
    """
    match = re.search(r"@define-color\s+base\s+#([0-9a-fA-F]{6})", palette)
    if not match:
        return False
    r, g, b = (int(match.group(1)[i : i + 2], 16) for i in (0, 2, 4))
    # Rec. 601 luma. Precision is not the point; which side of the middle is.
    return (0.299 * r + 0.587 * g + 0.114 * b) / 255 > 0.5


class Theme:
    """The stylesheet, kept in step with the desktop's theme.

    SUPER+SHIFT+T rewrites colors.css and signals waybar, kitty and mako to
    pick it up. An app that only read the palette at startup would sit there in
    the old colours until it was restarted, which is exactly the kind of small
    wrongness that makes something feel bolted on. So we watch the file.

    The watch is on the *directory*, not the file: theme.sh renders to a
    temporary file and moves it into place, and a monitor attached to the old
    inode stops hearing about anything after the first switch.
    """

    def __init__(self, display: Gdk.Display):
        self.on_change = None
        self.light = is_light(palette_css())
        self.provider = Gtk.CssProvider()
        self.provider.load_from_string(_css())
        Gtk.StyleContext.add_provider_for_display(
            display, self.provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )
        self._monitor = self._watch()

    def _watch(self):
        try:
            directory = Gio.File.new_for_path(str(paths.COLORS_CSS.parent))
            monitor = directory.monitor_directory(Gio.FileMonitorFlags.WATCH_MOVES, None)
        except Exception:
            return None  # no inotify is a reason to not follow along, not to fail
        monitor.connect("changed", self._on_change)
        return monitor

    def _on_change(self, _monitor, file, other, event):
        names = {f.get_basename() for f in (file, other) if f is not None}
        if paths.COLORS_CSS.name not in names:
            return
        if event in (
            Gio.FileMonitorEvent.CHANGES_DONE_HINT,
            Gio.FileMonitorEvent.CREATED,
            Gio.FileMonitorEvent.MOVED_IN,
            Gio.FileMonitorEvent.RENAMED,
        ):
            self.reload()

    def reload(self):
        try:
            palette = palette_css()
            self.light = is_light(palette)
            self.provider.load_from_string(
                palette + "\n" + (Path(__file__).parent / "style.css").read_text()
            )
        except Exception:
            return  # a half-written palette is transient; the next event wins
        if self.on_change:
            self.on_change()


def load(display: Gdk.Display) -> Theme:
    """Apply the stylesheet to `display` and keep it following the theme."""
    return Theme(display)
