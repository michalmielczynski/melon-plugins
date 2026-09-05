#!/usr/bin/env python3
"""melon.eye helper: emits cursor position and mouse clicks/taps to stdout.

Lines:
  P <x> <y>        cursor position in global layout coords (polled ~20 Hz)
  C <x> <y> <code> click (L/R/M) WITH the cursor position captured at the
                   moment of the click — the ring spawns exactly there.

Agreement with the system:
  - taps are detected like libinput (short, minimal movement in mm,
    gated on tap-to-click),
  - while the system has the touchpad disabled during typing
    (input:touchpad:disable-while-typing), touchpad taps/clicks are
    suppressed so the eye does not ring on clicks the system ignores.

Set MELON_EYE_DEBUG=1 to log tap candidates; MELON_EYE_DWT_MS to tune the
re-enable window (default 1000 ms).
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
DWT_MS = int(os.environ.get("MELON_EYE_DWT_MS", "1000"))
DEBUG = os.environ.get("MELON_EYE_DEBUG") == "1"

# device capability groups
KEYS_ABS = ec.EV_ABS
KEY_MAP = ec.ecodes.get("KEY_A")

# display names for named keys (letters/digits/F-keys handled generically)
NAMED_KEYS = {
    ec.KEY_ENTER: "⏎", ec.KEY_BACKSPACE: "⌫", ec.KEY_SPACE: "␣",
    ec.KEY_TAB: "⇥", ec.KEY_ESC: "⎋", ec.KEY_DELETE: "⌦",
    ec.KEY_UP: "↑", ec.KEY_DOWN: "↓", ec.KEY_LEFT: "←", ec.KEY_RIGHT: "→",
    ec.KEY_HOME: "⌂", ec.KEY_END: "⤓", ec.KEY_PAGEUP: "⇞",
    ec.KEY_PAGEDOWN: "⇟", ec.KEY_INSERT: "⌤", ec.KEY_CAPSLOCK: "⇪",
    ec.KEY_PRINT: "⎙", ec.KEY_PAUSE: "⏸", ec.KEY_MENU: "☰",
    ec.KEY_KPENTER: "⏎", ec.KEY_KPPLUS: "+", ec.KEY_KPMINUS: "−",
    ec.KEY_KPASTERISK: "×", ec.KEY_KPSLASH: "÷",
    ec.KEY_SEMICOLON: ";", ec.KEY_COMMA: ",", ec.KEY_DOT: ".",
    ec.KEY_SLASH: "/", ec.KEY_GRAVE: "`", ec.KEY_MINUS: "−",
    ec.KEY_EQUAL: "=", ec.KEY_LEFTBRACE: "[", ec.KEY_RIGHTBRACE: "]",
    ec.KEY_BACKSLASH: "\\", ec.KEY_APOSTROPHE: "'",
}

MOD_KEYS = {
    ec.KEY_LEFTCTRL: "ctrl", ec.KEY_RIGHTCTRL: "ctrl",
    ec.KEY_LEFTSHIFT: "shift", ec.KEY_RIGHTSHIFT: "shift",
    ec.KEY_LEFTALT: "alt", ec.KEY_RIGHTALT: "alt",
    ec.KEY_LEFTMETA: "super", ec.KEY_RIGHTMETA: "super",
}


def key_display(code):
    """evdev keycode -> short display name, or None for unnamed."""
    if code in NAMED_KEYS:
        return NAMED_KEYS[code]
    if 30 <= code <= 57:  # KEY_A (30) .. KEY_0 (11) region? letters A-Z = 30..44
        try:
            n = ec.KEY[code]
        except Exception:
            return None
        if n.startswith("KEY_"):
            sym = n[4:]
            if len(sym) == 1 and sym.isalpha():
                return sym.upper()
    if 2 <= code <= 11:  # KEY_1..KEY_9, KEY_0
        try:
            n = ec.KEY[code]
        except Exception:
            return None
        if n.startswith("KEY_"):
            digits = n[4:]
            if digits.isdigit():
                return digits
    if 59 <= code <= 70 or 112 <= code <= 115:  # KEY_F1..F12
        try:
            n = ec.KEY[code]
        except Exception:
            return None
        if n.startswith("KEY_F"):
            return n[4:]
    return None


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


def read_option(key):
    try:
        out = subprocess.run(["hyprctl", "getoption", key],
                             capture_output=True, text=True, timeout=3)
        return out.stdout
    except Exception:
        return ""


def option_bool(key):
    return "true" in read_option(key).lower()


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


def classify_devices():
    """Return (keyboards, mice, touchpads). Keyboards have many KEY_* and
    no BTN_LEFT/BTN_TOUCH; mice have physical buttons; touchpads have
    BTN_TOUCH + ABS."""
    keyboards = []
    mice = []
    touchpads = {}
    for path in evdev.list_devices():
        try:
            dev = evdev.InputDevice(path)
        except OSError:
            continue
        keys = dev.capabilities().get(ec.EV_KEY, [])
        has_btn = ec.BTN_LEFT in keys or ec.BTN_RIGHT in keys or ec.BTN_MIDDLE in keys
        has_touch = ec.BTN_TOUCH in keys
        has_abs = ec.EV_ABS in dev.capabilities()
        letters = sum(1 for c in keys if 30 <= c <= 51)  # KEY_A..KEY_Z
        if has_touch and has_abs:
            resx = resy = 31.0
            for code, inf in dev.capabilities().get(ec.EV_ABS, []):
                if code == ec.ABS_X and inf.resolution:
                    resx = float(inf.resolution)
                elif code == ec.ABS_Y and inf.resolution:
                    resy = float(inf.resolution)
            touchpads[dev.fd] = (dev, resx, resy)
        elif has_btn:
            mice.append(dev)
        elif letters >= 5:
            keyboards.append(dev)
    return keyboards, mice, touchpads


def click_loop():
    keyboards, mice, touchpads = classify_devices()

    fds = {dev.fd: dev for dev in mice}
    fds.update({dev.fd: dev for dev, _, _ in touchpads.values()})
    fds.update({dev.fd: dev for dev in keyboards})

    tool_fingers = {
        ec.BTN_TOOL_FINGER: 1,
        ec.BTN_TOOL_DOUBLETAP: 2,
        ec.BTN_TOOL_TRIPLETAP: 3,
        ec.BTN_TOOL_QUADTAP: 4,
    }

    last_btn = 0.0
    touch = {}  # fd -> [t0, sx, sy, cx, cy, fingers]
    dwt_enabled = option_bool("input:touchpad:disable-while-typing")
    key_until = 0.0
    last_dwt_check = 0.0
    held_mods = set()

    def emit_click(code):
        pos = query_cursor()
        if pos:
            print("C %d %d %s" % (pos[0], pos[1], code), flush=True)

    MOD_ORDER = ["ctrl", "alt", "shift", "super"]

    def mods_str():
        return ",".join(m for m in MOD_ORDER if m in held_mods)

    while True:
        ready, _, _ = select.select(list(fds), [], [], 1.0)
        if not parent_alive():
            os._exit(0)
        now = time.monotonic()

        # refresh the DWT-enabled config periodically
        if now - last_dwt_check > 3.0:
            dwt_enabled = option_bool("input:touchpad:disable-while-typing")
            last_dwt_check = now

        for fd in ready:
            try:
                events = fds[fd].read()
            except OSError:
                continue
            is_touch = fd in touchpads
            is_kbd = fd in {dev.fd for dev in keyboards}
            rx, ry = (touchpads[fd][1], touchpads[fd][2]) if is_touch else (31.0, 31.0)
            for ev in events:
                if ev.type == ec.EV_KEY:
                    if is_kbd:
                        if ev.code in MOD_KEYS:
                            mod = MOD_KEYS[ev.code]
                            if ev.value == 1:
                                held_mods.add(mod)
                                key_until = now + DWT_MS / 1000.0
                                print("M %s 1" % mod, flush=True)
                            else:
                                held_mods.discard(mod)
                                print("M %s 0" % mod, flush=True)
                            continue
                        # a key press arms the typing suppression window
                        if ev.value == 1:
                            key_until = now + DWT_MS / 1000.0
                            name = key_display(ev.code)
                            if name:
                                print("K %s %s" % (name, mods_str()), flush=True)
                        continue
                    if ev.value == 1:
                        if ev.code == ec.BTN_LEFT:
                            last_btn = now
                            if is_touch and dwt_enabled and now < key_until:
                                continue  # system ignores the touchpad while typing
                            emit_click("L")
                        elif ev.code == ec.BTN_RIGHT:
                            last_btn = now
                            if is_touch and dwt_enabled and now < key_until:
                                continue
                            emit_click("R")
                        elif ev.code == ec.BTN_MIDDLE:
                            last_btn = now
                            if is_touch and dwt_enabled and now < key_until:
                                continue
                            emit_click("M")
                    if is_touch and ev.code == ec.BTN_TOUCH:
                        if ev.value == 1:
                            touch[fd] = [now, None, None, None, None, 1]
                        else:
                            st = touch.get(fd)
                            if st is not None:
                                t0, sx, sy, cx, cy, fingers = st
                                dur = now - t0
                                dist = (math.hypot((cx - sx) / rx, (cy - sy) / ry)
                                        if sx is not None and cx is not None
                                        and sy is not None and cy is not None else 0.0)
                                if DEBUG:
                                    print("tapcand dur=%.0fms dist=%.2fmm f=%d dwt=%s" %
                                          (dur * 1000, dist, fingers, dwt_enabled),
                                          flush=True)
                                suppress = (dwt_enabled and now < key_until)
                                if (dur <= TAP_MAX_S
                                        and dist <= TAP_MAX_MOVE_MM
                                        and (now - last_btn) > PHYS_DEDUP_S
                                        and not suppress
                                        and option_bool("input:touchpad:tap-to-click")):
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


if SOCK:
    threading.Thread(target=cursor_loop, daemon=True).start()
click_loop()
