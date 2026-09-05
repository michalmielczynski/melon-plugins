#!/usr/bin/env python3
"""melon.eye helper: emits cursor position and mouse clicks/taps to stdout.

Lines:
  P <x> <y>    cursor position in global layout coords (polled via Hyprland IPC)
  L / R / M    mouse click: physical buttons AND touchpad tap-to-click taps

Tap detection is done from raw evdev touch events (BTN_TOUCH + finger count +
duration + movement), because libinput synthesises tap-clicks above the evdev
layer, so taps never show up as BTN_LEFT in /dev/input.
"""
import glob
import json
import math
import os
import select
import socket
import threading
import time

import evdev

ec = evdev.ecodes

TAP_MAX_S = 0.25        # a tap is a touch shorter than this
TAP_MAX_MOVE = 200.0    # device units (~10 mm on a typical touchpad)
PHYS_DEDUP_S = 0.3      # ignore a tap right after a physical button press


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

# Self-healing lifecycle: when the parent (omarchy-shell) dies we get
# reparented to init — exit instead of lingering as an orphan.
PARENT_PID = os.getppid()


def parent_alive():
    return os.getppid() == PARENT_PID


def cursor_loop():
    """Poll Hyprland IPC for the cursor position. Hyprland closes the
    connection after every response, so connect/query/close per cycle."""
    while True:
        if not parent_alive():
            os._exit(0)
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
            print("P %d %d" % (obj["x"], obj["y"]), flush=True)
        except Exception:
            pass
        time.sleep(0.05)  # ~20 Hz


def click_loop():
    buttons = []    # mice etc. with physical buttons
    touchpads = []  # touch-capable devices (touchpad / touchscreen)
    for path in evdev.list_devices():
        try:
            dev = evdev.InputDevice(path)
        except OSError:
            continue
        caps = dev.capabilities().get(ec.EV_KEY, [])
        if ec.BTN_LEFT in caps or ec.BTN_RIGHT in caps or ec.BTN_MIDDLE in caps:
            buttons.append(dev)
        if ec.BTN_TOUCH in caps and ec.EV_ABS in dev.capabilities():
            touchpads.append(dev)

    fds = {dev.fd: dev for dev in buttons + touchpads}

    last_btn = 0.0
    touch_t0 = None
    touch_sx = touch_sy = 0.0
    touch_cx = touch_cy = 0.0
    touch_fingers = 0

    tool_fingers = {
        ec.BTN_TOOL_FINGER: 1,
        ec.BTN_TOOL_DOUBLETAP: 2,
        ec.BTN_TOOL_TRIPLETAP: 3,
        ec.BTN_TOOL_QUADTAP: 4,
    }

    def emit(code):
        print(code, flush=True)

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
            is_touch = fds[fd] in touchpads
            for ev in events:
                if ev.type == ec.EV_KEY:
                    if ev.value == 1:
                        if ev.code == ec.BTN_LEFT:
                            last_btn = now
                            emit("L")
                        elif ev.code == ec.BTN_RIGHT:
                            last_btn = now
                            emit("R")
                        elif ev.code == ec.BTN_MIDDLE:
                            last_btn = now
                            emit("M")
                    if is_touch:
                        if ev.code == ec.BTN_TOUCH:
                            if ev.value == 1:
                                touch_t0 = now
                                touch_sx = touch_cx
                                touch_sy = touch_cy
                                touch_fingers = 1
                            else:  # finger lifted -> possible tap
                                if touch_t0 is not None:
                                    dur = now - touch_t0
                                    dist = math.hypot(touch_cx - touch_sx,
                                                      touch_cy - touch_sy)
                                    if (dur <= TAP_MAX_S
                                            and dist <= TAP_MAX_MOVE
                                            and (now - last_btn) > PHYS_DEDUP_S):
                                        emit("L" if touch_fingers <= 1 else "R")
                                    touch_t0 = None
                        elif ev.code in tool_fingers:
                            if ev.value == 1:
                                touch_fingers = max(touch_fingers,
                                                    tool_fingers[ev.code])
                elif ev.type == ec.EV_ABS and is_touch:
                    if ev.code == ec.ABS_X:
                        touch_cx = ev.value
                    elif ev.code == ec.ABS_Y:
                        touch_cy = ev.value


if SOCK:
    threading.Thread(target=cursor_loop, daemon=True).start()
click_loop()
