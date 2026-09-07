"""The handful of widgets libadwaita would have given us.

A settings app is almost entirely one shape: a title, an optional line of
explanation under it, and a control pushed to the right. libadwaita calls that
an ActionRow. Writing it by hand is about a screen of code and buys back
complete control of the styling, which is the whole reason for not using
libadwaita here.
"""

from gi.repository import Gtk


def _label(text, css, *, wrap=False):
    label = Gtk.Label(label=text, xalign=0.0)
    label.add_css_class(css)
    if wrap:
        label.set_wrap(True)
        label.set_max_width_chars(52)
    return label


class Row(Gtk.Box):
    """Title (and optional subtitle) on the left, control on the right."""

    def __init__(self, title, control=None, subtitle=None):
        super().__init__(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        self.add_css_class("sc-row")

        text = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=1)
        text.set_hexpand(True)
        text.set_valign(Gtk.Align.CENTER)
        text.append(_label(title, "sc-row-title"))
        if subtitle:
            text.append(_label(subtitle, "sc-row-subtitle", wrap=True))
        self.append(text)

        self.control = control
        if control is not None:
            control.set_valign(Gtk.Align.CENTER)
            self.append(control)


class Card(Gtk.Box):
    """A rounded group of rows, with hairlines between them.

    Separators are added by the card rather than by the rows so that the first
    and last row never draw one — the same reason a list draws its own rules.
    """

    def __init__(self):
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self.add_css_class("sc-card")
        self._empty = True

    def add(self, row):
        if not self._empty:
            sep = Gtk.Box()
            sep.add_css_class("sc-row-sep")
            self.append(sep)
        self._empty = False
        self.append(row)
        return row


class Page(Gtk.Box):
    """A scrollable settings page: heading, then any number of sections."""

    def __init__(self, title, subtitle=None):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        self.add_css_class("sc-content")

        self.append(_label(title, "sc-page-title"))
        if subtitle:
            self.append(_label(subtitle, "sc-page-subtitle", wrap=True))

    def section(self, title):
        """Add a titled section and return the card to put rows in."""
        self.append(_label(title.upper(), "sc-section-title"))
        card = Card()
        self.append(card)
        return card

    def note(self, text):
        label = _label(text, "sc-row-subtitle", wrap=True)
        label.set_margin_top(8)
        label.set_margin_start(4)
        self.append(label)
        return label


def dropdown(options, selected=0, on_change=None):
    """A Gtk.DropDown over a list of display strings."""
    widget = Gtk.DropDown.new_from_strings(list(options))
    widget.set_selected(selected if 0 <= selected < len(options) else 0)
    if on_change:
        # notify::selected fires while the list is being populated too, so
        # callers get the index and decide for themselves whether it is news.
        widget.connect("notify::selected", lambda w, _p: on_change(w.get_selected()))
    return widget


def switch(active=False, on_change=None):
    widget = Gtk.Switch()
    widget.set_active(bool(active))
    if on_change:
        widget.connect("notify::active", lambda w, _p: on_change(w.get_active()))
    return widget


def button(text, *, accent=False, on_click=None):
    widget = Gtk.Button(label=text)
    if accent:
        widget.add_css_class("sc-accent")
    if on_click:
        widget.connect("clicked", lambda _w: on_click())
    return widget
