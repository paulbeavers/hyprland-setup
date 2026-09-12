"""Welcome — the page the desktop opens on first login.

It exists to do two things and then get out of the way: say what this app is,
and offer to stop appearing. A first-run screen that cannot be dismissed
permanently is a nuisance rather than a welcome.
"""

from pathlib import Path

from gi.repository import Gtk

from .. import hypr, state
from ..widgets import Page, Row, switch

INTRO = (
    "Everything here writes a plain file you can read, edit or delete. "
    "Nothing runs in the background to keep it that way."
)

TOUR = [
    ("\U000f0369", "Display",
     "Resolution, refresh rate, and a scale menu that only offers the values "
     "your screen can actually use."),
    ("\U000f04b2", "Idle",
     "When the screen dims, blanks and locks, when the machine suspends, and "
     "what closing the lid does."),
    ("\U000f030c", "Input",
     "Keyboard layout, what Caps Lock does, key repeat, and the touchpad."),
    ("\U000f03d8", "Look",
     "Theme, wallpaper, cursor and font size. The theme applies everywhere at "
     "once, including this window."),
]


def build(window):
    page = Page("")  # the logo is the heading

    logo = _logo()
    if logo is not None:
        page.append(logo)

    hello = Gtk.Label(xalign=0.5)
    hello.add_css_class("sc-page-subtitle")
    hello.set_wrap(True)
    hello.set_max_width_chars(58)
    hello.set_justify(Gtk.Justification.CENTER)
    hello.set_text(INTRO)
    hello.set_margin_bottom(6)
    page.append(hello)

    card = page.section("What is here")
    for icon, name, what in TOUR:
        row = Row(name, subtitle=what)
        glyph = Gtk.Label(label=icon)
        glyph.add_css_class("sc-nav-icon")
        glyph.set_valign(Gtk.Align.CENTER)
        row.prepend(glyph)
        card.add(row)

    card = page.section("At login")
    card.add(Row(
        "Show this at login",
        switch(state.get("show_at_login"), on_change=_set_show_at_login),
        "Turn this off and starch-config stays out of the way until you open "
        "it yourself, with SUPER+I.",
    ))

    if not hypr.available():
        page.note("No compositor answered, so the other pages have nothing to "
                  "read. Start Hyprland and reopen starch-config.")
    return page


def _set_show_at_login(value):
    # Written immediately rather than staged with the rest. The footer's Apply
    # is about changing the machine; this is about whether a window opens, and
    # making someone press Apply to dismiss a greeter is the opposite of the
    # point.
    state.set("show_at_login", bool(value))


def _logo():
    path = Path(__file__).parent.parent / "assets" / "logo.png"
    if not path.exists():
        return None
    image = Gtk.Picture.new_for_filename(str(path))
    image.set_content_fit(Gtk.ContentFit.CONTAIN)
    image.set_can_shrink(True)
    image.set_size_request(-1, 190)
    image.set_margin_top(10)
    image.set_margin_bottom(14)
    return image
