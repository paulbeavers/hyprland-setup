#!/usr/bin/env bash
# waybar.sh — start waybar with SIGRTMIN+1 ignored until waybar itself claims it.
#
# The workspace row is ten custom modules refreshed by SIGRTMIN+1, which
# autostart.lua sends on every workspace and window event (see the block there
# for why the row is built that way). A real-time signal has no default
# handler, and the default action for one is to *terminate* the process — so
# any event that fires in the second or two between exec'ing waybar and waybar
# installing its handler kills the bar outright. Silently: no message on stdout
# or stderr, nothing in the journal, no core. The desktop simply comes up with
# no bar.
#
# That window is wide enough to matter. On install media the installer opens
# about two seconds in, and every window.open and workspace.created along the
# way is another shot at it; with a cold page cache — a live session reading
# waybar and its libraries off the medium for the first time — it lost the race
# every single time.
#
# SIG_IGN survives execve, so ignoring the signal here makes those early shots
# harmless, and waybar's own sigaction replaces the disposition the moment it
# is ready. Nothing is lost by dropping the early ones: each module runs its
# script once at startup, so the row is already correct when the bar appears.
#
# The bare `waybar` name is also why autostart matches with `pkill -x`: without
# it the substring would match this wrapper too, in the moment before it execs.
trap '' RTMIN+1
exec waybar "$@"
