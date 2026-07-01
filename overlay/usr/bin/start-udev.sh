#!/usr/bin/env bash
###
# File: start-udev.sh
# Project: bin
# File Created: Tuesday, 12th January 2022 8:46:47 am
# Author: Josh.5 (jsunnex@gmail.com)
# -----
# Last Modified: Friday, 14th January 2022 9:21:00 am
# Modified By: Josh.5 (jsunnex@gmail.com)
###
set -e

# CATCH TERM SIGNAL:
_term() {
    kill -TERM "${sync_pid:-}" 2>/dev/null
    kill -TERM "${monitor_pid:-}" 2>/dev/null
}
trap _term SIGTERM SIGINT

# The container's /dev is a plain tmpfs (not devtmpfs) and modern udevd does not
# mknod device nodes. Sunshine creates its virtual input devices dynamically
# (on client connect), so their /dev/input/* nodes never appear and Xorg fails to
# open them ("Unable to open evdev device"). Create any missing nodes from sysfs.
# Returns 0 if it created at least one node, 1 otherwise.
sync_input_nodes() {
    local made=1 sys node major minor
    for sys in /sys/class/input/*/dev; do
        [ -f "${sys}" ] || continue
        node="/dev/input/$(basename "$(dirname "${sys}")")"
        [ -e "${node}" ] && continue
        IFS=: read -r major minor < "${sys}"
        if mknod "${node}" c "${major}" "${minor}" 2>/dev/null; then
            chmod 0660 "${node}" 2>/dev/null || true
            chgrp input "${node}" 2>/dev/null || true
            made=0
        fi
    done
    return ${made}
}

# EXECUTE PROCESS:
# Start udev
# NOTE: udevd must run in the same network namespace as Xorg. udev monitor
# events travel over per-netns netlink, so running udevd under "unshare --net"
# (as was done here to stop udev renaming host network interfaces) severs
# input hotplug from Xorg and Sunshine's virtual mouse/keyboard never attach.
if command -v udevd &>/dev/null; then
    udevd --daemon &>/dev/null
else
    /lib/systemd/systemd-udevd --daemon &>/dev/null
fi
# Monitor kernel uevents
udevadm monitor &
monitor_pid=$!
# Create nodes for devices present now, then request device events from the kernel
sync_input_nodes || true
sleep 5
udevadm trigger

# Keep materialising nodes for input devices created later (Sunshine's virtual
# mouse/keyboard). When a new node is made, re-trigger so Xorg attaches it.
while true; do
    if sync_input_nodes; then
        udevadm trigger --action=add --subsystem-match=input >/dev/null 2>&1
    fi
    sleep 2
done &
sync_pid=$!

# WAIT FOR CHILD PROCESS:
wait "$monitor_pid"
