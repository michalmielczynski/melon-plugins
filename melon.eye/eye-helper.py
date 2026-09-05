#!/usr/bin/env python3
"""melon.eye helper: emits cursor position and mouse clicks to stdout.

Lines:
  P <x> <y>    cursor position in global layout coords (polled via Hyprland IPC)
  L / R / M    mouse button press (evdev)

The QML widget parses these lines; rendering stays in QML (GPU).
"""
import glob
import json
import os
import select
import socket
import threading
import time

import evdev

ec = evdev.ecodes

# --- Hyprland IPC socket path -------------------------------------------------
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

# Self-healing lifecycle: when the parent (omarchy-shell) dies or the widget is
# destroyed, we get reparented to init — exit instead of lingering as an orphan.
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
    devices = []
    for path in evdev.list_devices():
        try:
            dev = evdev.InputDevice(path)
        except OSError:
            continue
        caps = dev.capabilities().get(ec.EV_KEY, [])
        if ec.BTN_LEFT in caps or ec.BTN_RIGHT in caps or ec.BTN_MIDDLE in caps:
            devices.append(dev)
    if not devices:
        return
    fds = {dev.fd: dev for dev in devices}
    while True:
        ready, _, _ = select.select(list(fds), [], [], 1.0)
        if not parent_alive():
            os._exit(0)
        for fd in ready:
            try:
                events = fds[fd].read()
            except OSError:
                continue
            for ev in events:
                if ev.type == ec.EV_KEY and ev.value == 1:
                    if ev.code == ec.BTN_LEFT:
                        print("L", flush=True)
                    elif ev.code == ec.BTN_RIGHT:
                        print("R", flush=True)
                    elif ev.code == ec.BTN_MIDDLE:
                        print("M", flush=True)


if SOCK:
    threading.Thread(target=cursor_loop, daemon=True).start()
click_loop()
