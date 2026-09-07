"""Talking to the running compositor.

Everything goes through hyprctl rather than the socket directly: it is one
subprocess for a settings app that changes something twice a minute, and it
keeps us out of the business of locating instance signatures.

Note the dispatch form. With a Lua config Hyprland evaluates whatever follows
`dispatch` as Lua, so the old `hyprctl dispatch dpms off` is a syntax error that
fails silently. Anything this app sends is Lua.
"""

import json
import subprocess


class NotRunning(Exception):
    """No compositor answered. The app still works; live preview does not."""


def _run(args, *, check=True):
    try:
        out = subprocess.run(
            ["hyprctl", *args], capture_output=True, text=True, timeout=5
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise NotRunning(str(exc)) from exc
    if check and out.returncode != 0:
        raise NotRunning(out.stderr.strip() or "hyprctl failed")
    return out.stdout


def available() -> bool:
    try:
        _run(["version"])
        return True
    except NotRunning:
        return False


def query(*what):
    """A -j query, parsed. `what` is e.g. ("monitors",) or ("monitors", "all")."""
    return json.loads(_run([*what, "-j"]))


def monitors():
    """Connected outputs, each with the modes it advertises."""
    # "all" includes outputs that are connected but currently disabled, which
    # is the difference between a laptop with the lid shut showing one screen
    # and showing none.
    for args in (("monitors", "all"), ("monitors",)):
        try:
            return query(*args)
        except (NotRunning, json.JSONDecodeError):
            continue
    return []


def eval_lua(expr: str) -> str:
    """Evaluate Lua in the compositor. Used to preview a change instantly."""
    return _run(["repl", expr], check=False).strip()


def apply(table_expr: str) -> str:
    """hl.config({...}) with the given table, for a live preview."""
    return eval_lua(f"hl.config({table_expr}) return 'ok'")


def reload() -> str:
    return _run(["reload"], check=False).strip()
