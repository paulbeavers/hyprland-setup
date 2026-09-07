"""The window: a sidebar, a stack of pages, and a footer that only appears
when something is waiting to be applied.

Nothing takes effect the moment a control moves. A settings app that applies
instantly is pleasant until the setting is display scale, at which point a
mis-click can leave you looking at a screen you cannot read well enough to
undo it. So edits are staged, the footer says how many are pending, and Apply
is a deliberate act.
"""

import sys

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
from gi.repository import Gdk, Gio, Gtk  # noqa: E402

from . import theme  # noqa: E402
from .pages import display as display_page  # noqa: E402

APP_ID = "dev.starch.config"

# icon, label, module
SECTIONS = [
    ("\U000f0369", "Display", display_page),
    ("\U000f04b2", "Idle", None),
    ("\U000f030c", "Input", None),
    ("\U000f03d8", "Look", None),
    ("\U000f02fc", "About", None),
]


class Window(Gtk.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title="starch-config")

        # Undecorated, so the title bar below is the real one. GTK's own
        # decorations would draw their shadow and rounding outside our card and
        # the two would not line up.
        self.set_decorated(False)
        self.set_default_size(880, 620)

        shell = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        shell.add_css_class("shell")
        self.set_child(shell)

        shell.append(self._titlebar())

        body = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        body.set_vexpand(True)
        shell.append(body)

        self.stack = Gtk.Stack()
        self.stack.set_transition_type(Gtk.StackTransitionType.CROSSFADE)
        self.stack.set_transition_duration(120)
        self.stack.set_hexpand(True)

        body.append(self._sidebar())
        body.append(self._scrolled(self.stack))

        self.footer = self._footer()
        shell.append(self.footer)

        self._pending = {}
        self._refresh_footer()

    # ── chrome ───────────────────────────────────────────────────────────────
    def _titlebar(self):
        bar = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        bar.add_css_class("titlebar")

        name = Gtk.Label(label="starch")
        name.add_css_class("app-title")

        accent = Gtk.Label(label="config")
        accent.add_css_class("app-title-accent")

        bar.append(name)
        bar.append(accent)

        spacer = Gtk.Box()
        spacer.set_hexpand(True)
        bar.append(spacer)

        close = Gtk.Button(label="✕")
        close.add_css_class("window-close")
        close.connect("clicked", lambda _b: self.close())
        bar.append(close)

        # Everything but the button drags the window, since there is no
        # decoration to grab.
        handle = Gtk.WindowHandle()
        handle.set_child(bar)
        return handle

    def _sidebar(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        box.add_css_class("sidebar")

        self.nav = Gtk.ListBox()
        self.nav.set_selection_mode(Gtk.SelectionMode.SINGLE)
        self.nav.connect("row-selected", self._on_nav)

        for icon, label, module in SECTIONS:
            row = Gtk.ListBoxRow()
            line = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
            glyph = Gtk.Label(label=icon)
            glyph.add_css_class("nav-icon")
            line.append(glyph)
            line.append(Gtk.Label(label=label, xalign=0.0))
            row.set_child(line)
            row.page_name = label
            self.nav.append(row)

            if module is not None:
                page = module.build(self)
            else:
                page = _placeholder(label)
            self.stack.add_named(self._scrolled_page(page), label)

        box.append(self.nav)
        self.nav.select_row(self.nav.get_row_at_index(0))
        return box

    @staticmethod
    def _scrolled(child):
        sw = Gtk.ScrolledWindow()
        sw.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        sw.set_child(child)
        sw.set_hexpand(True)
        return sw

    def _scrolled_page(self, page):
        return self._scrolled(page)

    def _footer(self):
        bar = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        bar.add_css_class("footer")

        self.status = Gtk.Label(xalign=0.0)
        self.status.add_css_class("footer-note")
        self.status.set_hexpand(True)
        bar.append(self.status)

        self.revert_btn = Gtk.Button(label="Revert")
        self.revert_btn.connect("clicked", lambda _b: self.revert())
        bar.append(self.revert_btn)

        self.apply_btn = Gtk.Button(label="Apply")
        self.apply_btn.add_css_class("accent")
        self.apply_btn.connect("clicked", lambda _b: self.apply())
        bar.append(self.apply_btn)

        return bar

    # ── staged changes ───────────────────────────────────────────────────────
    def stage(self, key, apply_fn, description):
        """Record a pending change. `key` replaces an earlier edit to the same
        setting, so moving one dropdown twice counts once."""
        self._pending[key] = (apply_fn, description)
        self._refresh_footer()

    def unstage(self, key):
        self._pending.pop(key, None)
        self._refresh_footer()

    def revert(self):
        self._pending.clear()
        self._reload_pages()
        self._refresh_footer()
        self._say("Reverted.")

    def apply(self):
        errors = []
        for _key, (fn, description) in list(self._pending.items()):
            try:
                fn()
            except Exception as exc:  # a bad write should name itself, not vanish
                errors.append(f"{description}: {exc}")
        self._pending.clear()
        self._refresh_footer()
        if errors:
            self._say(" · ".join(errors), warn=True)
        else:
            self._say("Applied.")

    def _reload_pages(self):
        for _icon, label, module in SECTIONS:
            if module is None:
                continue
            page = self.stack.get_child_by_name(label)
            if page is not None:
                self.stack.remove(page)
            self.stack.add_named(self._scrolled(module.build(self)), label)
        row = self.nav.get_selected_row()
        if row is not None:
            self.stack.set_visible_child_name(row.page_name)

    def _refresh_footer(self):
        n = len(self._pending)
        self.apply_btn.set_sensitive(n > 0)
        self.revert_btn.set_sensitive(n > 0)
        if n:
            what = next(iter(self._pending.values()))[1] if n == 1 else f"{n} changes"
            self._say(f"{what} — not applied yet")
        else:
            self._say("")

    def _say(self, text, warn=False):
        self.status.set_text(text)
        if warn:
            self.status.add_css_class("warn")
        else:
            self.status.remove_css_class("warn")

    # ── nav ──────────────────────────────────────────────────────────────────
    def _on_nav(self, _listbox, row):
        if row is not None:
            self.stack.set_visible_child_name(row.page_name)


def _placeholder(name):
    from .widgets import Page

    page = Page(name, "Not built yet.")
    page.note("This section is next.")
    return page


class Application(Gtk.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.FLAGS_NONE)
        self._theme = None

    def do_activate(self):
        if self._theme is None:
            self._theme = theme.load(Gdk.Display.get_default())
        win = self.props.active_window or Window(self)
        win.present()


def main(argv):
    return Application().run(argv)
