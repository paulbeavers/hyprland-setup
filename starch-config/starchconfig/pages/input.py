"""Input — keyboard and touchpad.

Current values come from the running compositor rather than from a file,
because the compositor is the only thing that knows what actually took effect:
input.lua is the default, settings.lua overrides it, and a device rule can
override that again.

Writing goes the other way. Rather than edit input.lua, which is hand-written
and full of comments, the page emits hypr/settings.lua — a generated module
hyprland.lua loads last. hl.config sets one key and leaves its siblings alone,
so overriding four settings does not disturb the twenty around them.
"""

from .. import generate, hypr, paths
from ..widgets import Page, Row, dropdown, switch

# xkb layouts worth putting in a menu. Anything else can go in input.lua by
# hand, and this page will show it as the current value even so.
LAYOUTS = [
    ("us", "English (US)"),
    ("gb", "English (UK)"),
    ("de", "German"),
    ("fr", "French"),
    ("es", "Spanish"),
    ("it", "Italian"),
    ("se", "Swedish"),
    ("no", "Norwegian"),
    ("dk", "Danish"),
    ("fi", "Finnish"),
    ("pt", "Portuguese"),
    ("br", "Portuguese (Brazil)"),
    ("ru", "Russian"),
    ("pl", "Polish"),
    ("cz", "Czech"),
    ("tr", "Turkish"),
    ("jp", "Japanese"),
]

DELAYS = [200, 250, 300, 400, 500, 600, 750, 1000]
RATES = [15, 20, 25, 30, 40, 50, 60, 75]

# Caps Lock is the one xkb option people actually reach for.
CAPS = [
    ("", "Caps Lock"),
    ("caps:escape", "Escape"),
    ("caps:ctrl_modifier", "Control"),
    ("caps:none", "Nothing"),
]


def build(window):
    page = Page("Input", "Keyboard and touchpad.")

    if not hypr.available():
        page.note("No compositor answered, so there is nothing to read.")
        return page

    state = _InputState(window)

    card = page.section("Keyboard")
    card.add(Row("Layout", state.layout_control()))
    card.add(Row("Caps Lock acts as", state.caps_control(),
                 "Remapping it to Escape or Control is common; the key is "
                 "well placed and rarely wanted for what it does."))
    card.add(Row("Repeat delay", state.delay_control(),
                 "How long a key waits before it starts repeating."))
    card.add(Row("Repeat rate", state.rate_control(),
                 "How fast it repeats once it starts."))
    card.add(Row("Num Lock on at startup", state.switch_control(
        "numlock_by_default", "input:numlock_by_default")))

    if hypr.has_touchpad():
        card = page.section("Touchpad")
        card.add(Row("Natural scrolling", state.switch_control(
            "touchpad.natural_scroll", "input:touchpad:natural_scroll",
        ), "Content follows your fingers, the way it does on a phone."))
        card.add(Row("Tap to click", state.switch_control(
            "touchpad.tap-to-click", "input:touchpad:tap-to-click")))
        card.add(Row("Ignore the touchpad while typing", state.switch_control(
            "touchpad.disable_while_typing", "input:touchpad:disable_while_typing")))
    else:
        page.note("No touchpad found, so those settings are not shown.")

    page.note(
        "Applying writes hypr/settings.lua, which is loaded after the "
        "hand-written config so it wins. Delete that file to go back to the "
        "defaults in input.lua."
    )
    return page


class _InputState:
    """Tracks the values this page manages, keyed by their path in hl.config.

    Every one of them is written on Apply, not just the changed ones, because
    settings.lua is rewritten whole — a file that accumulated only the deltas
    of one session would slowly stop describing anything.
    """

    def __init__(self, window):
        self.window = window
        self.values = {}

    # ── controls ─────────────────────────────────────────────────────────────
    def layout_control(self):
        current = hypr.get_option("input:kb_layout") or "us"
        codes = [code for code, _name in LAYOUTS]
        names = [name for _code, name in LAYOUTS]
        if current not in codes:  # something hand-set; keep it visible
            codes.insert(0, current)
            names.insert(0, current)
        self.values["kb_layout"] = current
        return dropdown(
            names,
            selected=codes.index(current),
            on_change=lambda i: self._set("kb_layout", codes[i]),
        )

    def caps_control(self):
        current = hypr.get_option("input:kb_options") or ""
        codes = [code for code, _name in CAPS]
        names = [name for _code, name in CAPS]
        if current not in codes:
            codes.insert(0, current)
            names.insert(0, current or "(none)")
        self.values["kb_options"] = current
        return dropdown(
            names,
            selected=codes.index(current),
            on_change=lambda i: self._set("kb_options", codes[i]),
        )

    def delay_control(self):
        return self._number_control(
            "repeat_delay", "input:repeat_delay", DELAYS, 400, lambda v: f"{v} ms"
        )

    def rate_control(self):
        return self._number_control(
            "repeat_rate", "input:repeat_rate", RATES, 40, lambda v: f"{v} / second"
        )

    def _number_control(self, key, option, steps, default, label):
        current = hypr.get_option(option)
        current = default if current is None else int(current)
        options = sorted(set(steps) | {current})
        self.values[key] = current
        return dropdown(
            [label(v) for v in options],
            selected=options.index(current),
            on_change=lambda i: self._set(key, options[i]),
        )

    def switch_control(self, key, option):
        current = bool(hypr.get_option(option))
        self.values[key] = current
        return switch(current, on_change=lambda v: self._set(key, v))

    # ── staging ──────────────────────────────────────────────────────────────
    def _set(self, key, value):
        self.values[key] = value
        self.window.stage("input", self.apply, "input settings")

    def apply(self):
        # "touchpad.natural_scroll" -> nested under input.touchpad.
        config = {"input": {}}
        for key, value in self.values.items():
            target = config["input"]
            *parents, leaf = key.split(".")
            for part in parents:
                target = target.setdefault(part, {})
            target[leaf] = value
        generate.write(paths.SETTINGS_LUA, generate.settings_lua(config))
        hypr.reload()
