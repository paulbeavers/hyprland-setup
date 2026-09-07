"""Display — resolution, refresh rate and scale, per connected output.

The scale menu is the point of this page. Hyprland accepts any number and then
quietly snaps it to the nearest one that divides the resolution into whole
pixels, so a config can say 1.5 while the session runs at 1.6 and nothing
anywhere says so. Here the menu contains only the values that survive that
test, which means what you pick is what you get.
"""

from .. import generate, hypr, paths, scales
from ..widgets import Page, Row, dropdown


def build(window):
    page = Page("Display", "Resolution, refresh rate and scale for each screen.")

    monitors = hypr.monitors()
    if not monitors:
        page.note(
            "No compositor answered, so there is nothing to read. Start "
            "Hyprland and reopen starch-config."
        )
        return page

    state = [_MonitorState(m) for m in monitors]

    for st in state:
        card = page.section(st.title)
        st.attach(card, window, state)

    page.note(
        "Applying rewrites hypr/monitors.lua and reloads Hyprland. The previous "
        "file is kept as monitors.lua.bak."
    )
    return page


class _MonitorState:
    """The three dropdowns for one output, and the value each currently holds.

    Kept as an object because the menus depend on each other: changing
    resolution changes which refresh rates exist and which scales are legal, so
    the other two have to be rebuilt rather than left showing impossible
    options.
    """

    def __init__(self, monitor):
        self.name = monitor.get("name", "?")
        self.description = monitor.get("description", "")
        self.width = int(monitor.get("width") or 0)
        self.height = int(monitor.get("height") or 0)
        self.refresh = float(monitor.get("refreshRate") or 60.0)
        self.scale = float(monitor.get("scale") or 1.0)
        self.position = "{}x{}".format(monitor.get("x", 0), monitor.get("y", 0))
        self.modes = _parse_modes(monitor.get("availableModes") or [])

        if not self.modes:
            self.modes = {(self.width, self.height): [self.refresh]}

        self.resolution = (self.width, self.height)

    @property
    def title(self):
        if self.description:
            return f"{self.name} — {self.description}"
        return self.name

    # ── ui ───────────────────────────────────────────────────────────────────
    def attach(self, card, window, all_state):
        self.window = window
        self.all_state = all_state

        resolutions = sorted(self.modes, key=lambda r: (r[0] * r[1], r), reverse=True)
        self.resolutions = resolutions

        self.res_dd = dropdown(
            [f"{w} × {h}" for w, h in resolutions],
            selected=_index(resolutions, self.resolution),
            on_change=self._on_resolution,
        )
        card.add(Row("Resolution", self.res_dd))

        self.rate_row = Row("Refresh rate", self._rate_dropdown())
        card.add(self.rate_row)

        self.scale_row = Row(
            "Scale",
            self._scale_dropdown(),
            subtitle=self._scale_note(),
        )
        card.add(self.scale_row)

    def _rate_dropdown(self):
        self.rates = self.modes[self.resolution]
        return dropdown(
            [f"{r:g} Hz" for r in self.rates],
            selected=_index(self.rates, _nearest(self.refresh, self.rates)),
            on_change=self._on_rate,
        )

    def _scale_dropdown(self):
        w, h = self.resolution
        self.scale_options = scales.legal(w, h) or [1.0]
        self.scale = scales.nearest(self.scale, self.scale_options)
        return dropdown(
            [scales.label(s) for s in self.scale_options],
            selected=_index(self.scale_options, self.scale),
            on_change=self._on_scale,
        )

    def _scale_note(self):
        n = len(self.scale_options)
        w, h = self.resolution
        if n <= 2:
            return (
                f"{w}×{h} divides evenly at only {n} scale"
                f"{'' if n == 1 else 's'} — everything else would be snapped."
            )
        return f"{n} scales divide {w}×{h} into whole pixels."

    # ── edits ────────────────────────────────────────────────────────────────
    def _on_resolution(self, index):
        if not 0 <= index < len(self.resolutions):
            return
        chosen = self.resolutions[index]
        if chosen == self.resolution:
            return
        self.resolution = chosen

        # The other two menus were built for the old resolution.
        self.rate_row.control = self._rate_dropdown()
        _replace_control(self.rate_row)
        self.scale_row.control = self._scale_dropdown()
        _replace_control(self.scale_row)

        self._stage()

    def _on_rate(self, index):
        if 0 <= index < len(self.rates):
            self.refresh = self.rates[index]
            self._stage()

    def _on_scale(self, index):
        if 0 <= index < len(self.scale_options):
            self.scale = self.scale_options[index]
            self._stage()

    def _stage(self):
        w, h = self.resolution
        self.window.stage(
            f"display:{self.name}",
            _writer(self.all_state),
            f"{self.name} → {w}×{h} at {scales.label(self.scale)}",
        )

    def entry(self):
        w, h = self.resolution
        return {
            "output": self.name,
            "mode": f"{w}x{h}@{self.refresh:.2f}",
            "position": self.position,
            "scale": generate.scale_str(self.scale),
        }


def _writer(all_state):
    def apply():
        generate.write(
            paths.MONITORS_LUA,
            generate.monitors_lua([st.entry() for st in all_state]),
        )
        hypr.reload()

    return apply


def _replace_control(row):
    """Swap a row's control for a freshly built one."""
    from gi.repository import Gtk

    last = row.get_last_child()
    if last is not None:
        row.remove(last)
    row.control.set_valign(Gtk.Align.CENTER)
    row.append(row.control)


def _parse_modes(modes):
    """"5120x2160@120.00Hz" strings into {(w, h): [rates]}, deduplicated."""
    out = {}
    for text in modes:
        try:
            size, _, rate = text.partition("@")
            w, _, h = size.partition("x")
            key = (int(w), int(h))
            value = round(float(rate.rstrip("Hz")), 2)
        except (ValueError, AttributeError):
            continue
        out.setdefault(key, [])
        if value not in out[key]:
            out[key].append(value)
    for rates in out.values():
        rates.sort(reverse=True)
    return out


def _index(items, value):
    try:
        return items.index(value)
    except ValueError:
        return 0


def _nearest(value, options):
    return min(options, key=lambda o: abs(o - value)) if options else value
