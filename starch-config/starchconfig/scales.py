"""Which scales a display can actually use.

This is the setting that sent us here in the first place: a retina panel comes
up unreadably small, you set a scale, and Hyprland silently snaps it to
something else. It does not report an error — it just picks the nearest legal
value and carries on, so the number in the config and the number in effect
quietly disagree.

A scale is legal when it is a multiple of 1/120 (the Wayland fractional-scale
step) and dividing the resolution by it lands on a whole pixel in both axes.
Rather than let anyone type a number that will be ignored, the app offers only
the values that survive that test.
"""

STEP = 1 / 120
EPSILON = 1e-6


def legal(width: int, height: int, lo: float = 1.0, hi: float = 3.0):
    """Every legal scale for this resolution, ascending."""
    out = []
    for n in range(round(lo * 120), round(hi * 120) + 1):
        scale = n * STEP
        if _whole(width / scale) and _whole(height / scale):
            out.append(round(scale, 7))
    return out


def _whole(value: float) -> bool:
    return abs(value - round(value)) < EPSILON


def nearest(scale: float, options) -> float:
    """The legal scale closest to `scale` — what Hyprland would have picked."""
    if not options:
        return scale
    return min(options, key=lambda s: abs(s - scale))


def label(scale: float) -> str:
    """How a scale is written in the UI.

    Percentages, because "133%" means something to everyone and "1.3333334"
    means something to about four people. The exact value still goes into the
    config; this is only what the menu says.
    """
    return f"{round(scale * 100)}%"
