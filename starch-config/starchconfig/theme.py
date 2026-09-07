"""Load the stylesheet, with the live palette in front of it.

theme.sh already renders the active theme to waybar/colors.css as a list of
@define-color declarations. Rather than teach it about a third consumer, we
read that file and paste it on top of our own stylesheet — so the app is themed
by whatever the desktop is themed by, and SUPER+SHIFT+T changes both.
"""

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
@define-color pink      #f5c2e7;
"""


def palette_css() -> str:
    try:
        text = paths.COLORS_CSS.read_text()
    except OSError:
        return FALLBACK
    # A colors.css that somehow defines nothing would leave every colour
    # undefined and GTK would drop the rules that use them, so check.
    return text if "@define-color" in text else FALLBACK


def _css() -> str:
    return palette_css() + "\n" + (Path(__file__).parent / "style.css").read_text()


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
            self.provider.load_from_string(_css())
        except Exception:
            pass  # a half-written palette is transient; the next event wins


def load(display: Gdk.Display) -> Theme:
    """Apply the stylesheet to `display` and keep it following the theme."""
    return Theme(display)
