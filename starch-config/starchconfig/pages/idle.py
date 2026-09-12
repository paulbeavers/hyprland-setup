"""Idle — what happens when you stop using the machine.

Four timeouts and the lid. They are dependent on each other in ways that are
easy to get wrong by hand: locking after suspending means the machine goes to
sleep unlocked, and blanking the screen before dimming it makes the dim
pointless. The page says so rather than letting you find out later.
"""

import subprocess

from .. import generate, paths, readback
from ..widgets import Page, Row, dropdown

# Offered timeouts, in seconds. None is "Never".
STEPS = [None, 30, 60, 120, 180, 300, 600, 900, 1200, 1800, 2700, 3600]

LID_ACTIONS = [
    ("suspend", "Suspend"),
    ("lock", "Lock only"),
    ("ignore", "Do nothing"),
]


def _label(seconds):
    if seconds is None:
        return "Never"
    if seconds < 60:
        return f"{seconds} seconds"
    minutes = seconds // 60
    return "1 minute" if minutes == 1 else f"{minutes} minutes"


def _closest(seconds):
    """Index of the offered step nearest an arbitrary value in the file."""
    if seconds is None:
        return 0
    return min(
        range(1, len(STEPS)), key=lambda i: abs(STEPS[i] - seconds)
    )


def build(window):
    page = Page("Idle", "What happens when you stop using the machine.")
    state = _IdleState(window, readback.hypridle_timeouts())

    card = page.section("Screen")
    card.add(Row("Dim the screen after", state.control("dim"),
                 "A warning that the screen is about to go dark."))
    card.add(Row("Turn the screen off after", state.control("blank")))
    card.add(Row("Lock after", state.control("lock")))

    card = page.section("Power")
    card.add(Row("Suspend after", state.control("suspend"),
                 "Applies to desktops too. Set it to Never on a machine that "
                 "should stay up."))

    if readback.has_battery():
        card = page.section("Lid")
        card.add(Row("Closing the lid", state.lid_control(),
                     "Ignored while an external monitor is connected."))

    state.warning = page.note("")
    state.check()
    page.note(
        "Applying rewrites hypr/hypridle.conf and restarts hypridle. The lid "
        "setting is system-wide and will ask for your password."
    )
    return page


class _IdleState:
    def __init__(self, window, current):
        self.window = window
        self.values = dict(current)
        self.lid = readback.lid_action()
        self.lid_original = self.lid
        self.warning = None

    def control(self, key):
        return dropdown(
            [_label(s) for s in STEPS],
            selected=_closest(self.values.get(key)),
            on_change=lambda i, k=key: self._set(k, i),
        )

    def lid_control(self):
        return dropdown(
            [text for _value, text in LID_ACTIONS],
            selected=next(
                (i for i, (v, _t) in enumerate(LID_ACTIONS) if v == self.lid), 0
            ),
            on_change=self._set_lid,
        )

    def _set(self, key, index):
        if not 0 <= index < len(STEPS):
            return
        self.values[key] = STEPS[index]
        self.check()
        self.window.stage("idle", self.apply, "idle timeouts")

    def _set_lid(self, index):
        if not 0 <= index < len(LID_ACTIONS):
            return
        self.lid = LID_ACTIONS[index][0]
        self.window.stage("idle", self.apply, "idle timeouts")

    # ── the parts that are easy to get wrong ─────────────────────────────────
    def check(self):
        if self.warning is None:
            return
        v = self.values
        problems = []
        if v["lock"] and v["suspend"] and v["lock"] > v["suspend"]:
            problems.append("suspending before locking leaves it asleep unlocked")
        if v["dim"] and v["blank"] and v["dim"] > v["blank"]:
            problems.append("the screen goes dark before it dims, so the dim never shows")
        if v["suspend"] and not v["lock"]:
            problems.append("nothing locks it, so waking goes straight to the desktop")

        if problems:
            self.warning.set_text("Careful: " + "; ".join(problems) + ".")
            self.warning.add_css_class("sc-warn")
        else:
            self.warning.set_text("")
            self.warning.remove_css_class("sc-warn")

    # ── writing ──────────────────────────────────────────────────────────────
    def apply(self):
        v = self.values
        generate.write(
            paths.HYPRIDLE_CONF,
            generate.hypridle_conf(v["dim"], v["blank"], v["lock"], v["suspend"]),
        )
        _restart_hypridle(any(v.values()))
        if self.lid != self.lid_original:
            _write_lid(self.lid)
            self.lid_original = self.lid


def _restart_hypridle(wanted: bool):
    """hypridle re-reads its config only at startup, so it has to be replaced.

    With every timeout set to Never there is nothing for it to do, and a
    hypridle holding a config with no rules logs an error on every start. Stop
    it instead — the absence of the daemon is a truer statement of "no idle
    handling" than a daemon configured to do nothing.
    """
    try:
        subprocess.run(["pkill", "-x", "hypridle"], capture_output=True)
        if not wanted:
            return
        subprocess.Popen(
            ["hypridle"],
            start_new_session=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError as exc:
        # Apply reports this; it must not raise into the toolkit.
        raise RuntimeError(f"could not restart hypridle: {exc}") from exc


LID_TEMPLATE = """# {banner}. Edits here are overwritten.
#
# systemd's own default is suspend; this file exists so the choice is explicit
# and survives a logind upgrade rewriting logind.conf.
[Login]
HandleLidSwitch={action}
HandleLidSwitchExternalPower={action}
# Docked means an external monitor is attached, where closing the lid is
# usually just closing the lid.
HandleLidSwitchDocked=ignore
"""


def _write_lid(action: str):
    """The one setting here that lives outside the home directory."""
    body = LID_TEMPLATE.format(banner=generate.BANNER, action=action)
    try:
        result = subprocess.run(
            [
                "pkexec",
                "/bin/sh",
                "-c",
                # logind can reload, so the setting takes effect now rather
                # than at the next boot. Reload rather than restart:
                # restarting logind takes the session down with it.
                "mkdir -p /etc/systemd/logind.conf.d && "
                "cat > /etc/systemd/logind.conf.d/10-starch-lid.conf && "
                "systemctl reload systemd-logind",
            ],
            input=body,
            text=True,
            capture_output=True,
        )
    except OSError as exc:
        raise RuntimeError(f"could not run pkexec: {exc}") from exc

    if result.returncode != 0:
        raise RuntimeError(
            result.stderr.strip().splitlines()[-1]
            if result.stderr.strip()
            else "not authorised"
        )
