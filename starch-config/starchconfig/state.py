"""What the user chose, as opposed to what the system currently is.

Most of this app reads its values back out of the thing that holds them — the
compositor, hypridle.conf, gsettings — because that is the only honest answer
to "what is this machine doing". A few settings have nowhere like that to live:
"show this at login" is a preference about the app itself, and no other file
has an opinion about it.

One small JSON file, read and written whole. It is not a cache of the other
settings and must not become one; anything that can be read back from the
system should be.
"""

import json

from . import paths

DEFAULTS = {
    # First login shows it; the welcome page offers to stop that.
    "show_at_login": True,
}


def load() -> dict:
    values = dict(DEFAULTS)
    try:
        stored = json.loads(paths.STATE.read_text())
    except (OSError, ValueError):
        return values
    if isinstance(stored, dict):
        values.update({k: v for k, v in stored.items() if k in DEFAULTS})
    return values


def get(key):
    return load().get(key, DEFAULTS.get(key))


def set(key, value) -> None:  # noqa: A001 — reads better than set_value here
    values = load()
    values[key] = value
    paths.STATE.parent.mkdir(parents=True, exist_ok=True)
    tmp = paths.STATE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(values, indent=2, sort_keys=True) + "\n")
    tmp.replace(paths.STATE)
