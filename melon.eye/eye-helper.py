#!/usr/bin/env python3
"""melon.eye helper: emits cursor position and mouse clicks/taps to stdout.

Lines:
  P <x> <y>        cursor position in global layout coords (polled ~20 Hz)
  C <x> <y> <code> click (L/R/M) WITH the cursor position captured at the
                   moment of the click — the ring spawns exactly there.

Tap detection reads raw evdev touch events and tries to agree with what the
system (libinput) considers a tap-to-click:
  - the touch is short (<= TAP_MAX_S),
  - the finger barely moves (<= TAP_MAX_MOVE_MM, converted via the device
    resolution so it is resolution-independent),
  - tap-to-click is enabled on the system (Hyprland),
  - dedup against a physical button press.

Set MELON_EYE_DEBUG=1 to log tap candidates so thresholds can be calibrated.
"""
import glob
import json
import math
import os
import select
import socket
import subprocess
import threading
import time

import evdev

ec = evdev.ecodes

TAP_MAX_S = 0.25
TAP_MAX_MOVE_MM = 5.0
PHYS_DEDUP_S = 0.15
DEBUG = os.environ.get("MELON_EYE_DEBUG") == "1"


def find_ipc_socket():
    runtime = os.environ.get("XDG_RUNTIME_DIR", "/run/user/1000")
    sig = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
    if sig:
        cands = glob.glob(os.path.join(runtime, "hypr", sig, ".socket.sock"))
        if cands:
            return cands[0]
    cands = glob.glob(os.path.join(runtime, "hypr", "*", ".socket.sock"))
    return cands[0] if cands else None


SOCK = find_ipc_socket()
PARENT_PID = os.getppid()


def parent_alive():
    return os.getppid() == PARENT_PID


def tap_to_click_enabled():
    try:
        out = subprocess.run(
            ["hyprctl", "getoption", "input:touchpad:tap-to-click"],
            capture_output=True, text=True, timeout=3)
        return "true" in out.stdout.lower()
    except Exception:
        return True


def query_cursor():
    if not SOCK:
        return None
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(1.0)
        s.connect(SOCK)
        s.sendall(b"j/cursorpos")
        data = b""
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            data += chunk
        s.close()
        obj = json.loads(data.decode())
        return int(obj["x"]), int(obj["y"])
    except Exception:
        return None


def cursor_loop():
    while True:
        if not parent_alive():
            os._exit(0)
        pos = query_cursor()
        if pos:
            print("P %d %d" % pos, flush=True)
        time.sleep(0.05)


def click_loop(ttc):
    buttons = []
    touchpads = {}  # fd -> (dev, resx, resy)

    for path in evdev.list_devices():
        try:
            dev = evdev.InputDevice(path)
        except OSError:
            continue
        caps = dev.capabilities().get(ec.EV_KEY, [])
        if ec.BTN_LEFT in caps or ec.BTN_RIGHT in caps or ec.BTN_MIDDLE in caps:
            buttons.append(dev)
        if ec.BTN_TOUCH in caps and ec.EV_ABS in dev.capabilities():
            resx = resy = 31.0
            for code, inf in dev.capabilities().get(ec.EV_ABS, []):
                if code == ec.ABS_X and inf.resolution:
                    resx = float(inf.resolution)
                elif code == ec.ABS_Y and inf.resolution:
                    resy = float(inf.resolution)
            touchpads[dev.fd] = (dev, resx, resy)

    fds = {dev.fd: dev for dev in buttons}
    fds.update({dev.fd: dev for dev, _, _ in touchpads.values()})

    tool_fingers = {
        ec.BTN_TOOL_FINGER: 1,
        ec.BTN_TOOL_DOUBLETAP: 2,
        ec.BTN_TOOL_TRIPLETAP: 3,
        ec.BTN_TOOL_QUADTAP: 4,
    }

    last_btn = 0.0
    # per-fd touch state: t0, sx, sy, cx, cy, fingers
    touch = {}

    def emit_click(code):
        pos = query_cursor()
        if pos:
            print("C %d %d %s" % (pos[0], pos[1], code), flush=True)

    while True:
        ready, _, _ = select.select(list(fds), [], [], 1.0)
        if not parent_alive():
            os._exit(0)
        now = time.monotonic()
        for fd in ready:
            try:
                events = fds[fd].read()
            except OSError:
                continue
            is_touch = fd in touchpads
            rx, ry = (touchpads[fd][1], touchpads[fd][2]) if is_touch else (31.0, 31.0)
            for ev in events:
                if ev.type == ec.EV_KEY:
                    if ev.value == 1:
                        if ev.code == ec.BTN_LEFT:
                            last_btn = now
                            emit_click("L")
                        elif ev.code == ec.BTN_RIGHT:
                            last_btn = now
                            emit_click("R")
                        elif ev.code == ec.BTN_MIDDLE:
                            last_btn = now
                            emit_click("M")
                    if is_touch and ev.code == ec.BTN_TOUCH:
                        if ev.value == 1:
                            touch[fd] = [now, None, None, None, None, 1]
                        else:
                            st = touch.get(fd)
                            if st is not None:
                                t0, sx, sy, cx, cy, fingers = st
                                dur = now - t0
                                if sx is not None and cx is not None:
                                    dist = math.hypot((cx - sx) / rx, (cy - sy) / ry)
                                else:
                                    dist = 0.0
                                if DEBUG:
                                    print("tapcand dur=%.0fms dist=%.2fmm f=%d" %
                                          (dur * 1000, dist, fingers), flush=True)
                                if (_short_tap(dur, dist, fingers)
                                        and (now - last_btn) > PHYS_DEDUP_S
                                        and ttc):
                                    emit_click("L" if fingers <= 1 else "R")
                                touch.pop(fd, None)
                    elif is_touch and ev.code in tool_fingers:
                        if ev.value == 1:
                            st = touch.get(fd)
                            if st is not None:
                                st[5] = max(st[5], tool_fingers[ev.code])
                elif ev.type == ec.EV_ABS and is_touch:
                    st = touch.get(fd)
                    if st is not None:
                        if ev.code == ec.ABS_X:
                            if st[1] is None:
                                st[1] = ev.value
                            st[3] = ev.value
                        elif ev.code == ec.ABS_Y:
                            if st[2] is None:
                                st[2] = ev.value
                            st[4] = ev.value


def _short_tap(dur, dist_mm, fingers):
    return dur <= TAP_MAX_S and dist_mm <= TAP_MAX_MOVE_MM


if SOCK:
    threading.Thread(target=cursor_loop, daemon=True).start()
click_loop(tap_to_click_enabled())
