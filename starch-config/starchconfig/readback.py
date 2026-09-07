"""Reading the current settings out of the files that hold them.

A settings app that opens showing defaults instead of what the machine is
actually doing is worse than useless, so every page reads the real state. Where
the running compositor knows (input, displays) we ask it; where only a file
knows (idle timeouts, the lid) we parse the file, including the hand-written
one that shipped, because the first run happens before we have written
anything of our own.
"""

import re
from pathlib import Path

from . import paths

LID_CONF = Path("/etc/systemd/logind.conf.d/10-starch-lid.conf")


def hypridle_timeouts():
    """{"dim": secs|None, "blank": ..., "lock": ..., "suspend": ...}

    Listeners are identified by what they run, not by their position, so this
    survives the file being reordered or a listener being removed.
    """
    found = {"dim": None, "blank": None, "lock": None, "suspend": None}
    try:
        text = paths.HYPRIDLE_CONF.read_text()
    except OSError:
        return found

    for block in re.findall(r"listener\s*\{(.*?)\}", text, re.S):
        timeout = re.search(r"timeout\s*=\s*(\d+)", block)
        action = re.search(r"on-timeout\s*=\s*(.+)", block)
        if not (timeout and action):
            continue
        seconds, command = int(timeout.group(1)), action.group(1).strip()
        for key, needle in (
            ("dim", "brightnessctl"),
            ("blank", "dpms"),
            ("lock", "lock-session"),
            ("suspend", "suspend"),
        ):
            if needle in command and found[key] is None:
                found[key] = seconds
                break
    return found


def lid_action() -> str:
    """"suspend", "lock", "ignore" — what closing the lid does.

    systemd's own default is suspend, so that is what an absent drop-in means.
    """
    try:
        text = LID_CONF.read_text()
    except OSError:
        return "suspend"
    match = re.search(r"^\s*HandleLidSwitch\s*=\s*(\S+)", text, re.M)
    if not match:
        return "suspend"
    value = match.group(1).lower()
    return value if value in ("suspend", "lock", "ignore") else "suspend"


def has_battery() -> bool:
    """Whether this machine has a lid worth asking about."""
    power = Path("/sys/class/power_supply")
    if not power.is_dir():
        return False
    for entry in power.iterdir():
        try:
            if (entry / "type").read_text().strip() == "Battery":
                return True
        except OSError:
            continue
    return False
