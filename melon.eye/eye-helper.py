#!/usr/bin/env python3
"""melon.eye helper: emits cursor position and mouse clicks/taps to stdout.

Lines:
  P <x> <y>        cursor position in global layout coords (polled at
                   MELON_EYE_CURSOR_HZ, default 60).
  C <x> <y> <code> click WITH the cursor position captured at the moment of
                   the click — the ring spawns exactly there. Single left
                   click is L, a double click D, a triple T; right is R,
                   middle is M, and a green ring G is emitted on button-up
                   (a release).
  H <btn> <0|1>    physical button hold state (btn = L/R/M) so the cursor
                   ring can darken/thicken while a button stays pressed.

Matching the window ("1:1"):
  - taps are detected like libinput (short, minimal movement in mm,
    gated on tap-to-click),
  - while the system has the touchpad disabled during typing
    (input:touchpad:disable-while-typing), touchpad taps/clicks are
    suppressed so the eye does not ring on clicks the system ignores.
  - multi-clicks (double/triple) are coalesced into ONE event using the
    standard window-toolkit double-click convention: a second press of the
    same button within MELON_EYE_DBL_MS and within MELON_EYE_DBL_PX logical
    px of the previous press. That is exactly how the focused window decides
    a double-click happened, so the eye shows the same single reaction
    instead of a burst of rings.
  - modifier keys are NOT treated as "typing": holding Ctrl/Shift/Super and
    clicking must never be suppressed (the window still receives it).

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
# Cursor-position poll rate. The eye's cursor ring follows the mouse: raise it
# to 60/120/144 Hz to track the pointer as smoothly as the monitor refreshes.
CURSOR_HZ = int(os.environ.get("MELON_EYE_CURSOR_HZ", "60"))
# Multi-click (double/triple) coalescing. A second press of the same button
# within DBL_MS and within DBL_PX logical px of the previous press is a
# double-click (DBL_PX uses the SAME units as the "C" output, i.e. global
# layout px). These mirror the window toolkit's double-click heuristics.
DBL_MS = int(os.environ.get("MELON_EYE_DBL_MS", "400"))
DBL_PX = int(os.environ.get("MELON_EYE_DBL_PX", "8"))
# Re-enable window for the touchpad after typing (disable-while-typing).
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


LETTER_KEYS = {
    ec.KEY_Q: "Q", ec.KEY_W: "W", ec.KEY_E: "E", ec.KEY_R: "R", ec.KEY_T: "T",
    ec.KEY_Y: "Y", ec.KEY_U: "U", ec.KEY_I: "I", ec.KEY_O: "O", ec.KEY_P: "P",
    ec.KEY_A: "A", ec.KEY_S: "S", ec.KEY_D: "D", ec.KEY_F: "F", ec.KEY_G: "G",
    ec.KEY_H: "H", ec.KEY_J: "J", ec.KEY_K: "K", ec.KEY_L: "L",
    ec.KEY_Z: "Z", ec.KEY_X: "X", ec.KEY_C: "C", ec.KEY_V: "V", ec.KEY_B: "B",
    ec.KEY_N: "N", ec.KEY_M: "M",
}


def key_display(code):
    """evdev keycode -> short display name, or None for unnamed."""
    if code in NAMED_KEYS:
        return NAMED_KEYS[code]
    if code in LETTER_KEYS:
        return LETTER_KEYS[code]
    if 2 <= code <= 11:  # KEY_1..KEY_9, KEY_0
        try:
            n = ec.KEY[code]
        except Exception:
            return None
        if n.startswith("KEY_") and n[4:].isdigit():
            return n[4:]
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
    step = 1.0 / CURSOR_HZ
    while True:
        if not parent_alive():
            os._exit(0)
        pos = query_cursor()
        if pos:
            print("P %d %d" % pos, flush=True)
        time.sleep(step)


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


class TapTracker:
    """Reconstructs a libinput-like 'tap' from raw evdev events, per touchpad.

    A tap is a short touch during which the finger(s) barely move. Movement is
    measured from BOTH the legacy ABS_X/ABS_Y pointer AND the proper MT slots
    (ABS_MT_POSITION_*) — this fixes the old bug where only ABS_X/ABS_Y were
    watched: those stay frozen in MT mode, so every cursor drag was mistaken
    for a tap (movement appeared as zero distance). A multi-finger tap
    (2+ fingers close together, barely moving) reports a right click.

    Drive it with key(BTN_TOUCH/BTN_TOOL_*), abs(...); finish(now, ...) after a
    BTN_TOUCH release returns 'L'/'R' for a tap, else None.
    """
    _TOOL = {ec.BTN_TOOL_FINGER: 1, ec.BTN_TOOL_DOUBLETAP: 2,
             ec.BTN_TOOL_TRIPLETAP: 3, ec.BTN_TOOL_QUADTAP: 4}

    def __init__(self, rx, ry):
        self.rx = rx if rx else 31.0
        self.ry = ry if ry else 31.0
        self.reset()

    def reset(self):
        self.t0 = None          # BTN_TOUCH down time (monotonic)
        self.cur = 0            # active MT slot
        self.fingers = 1        # max tool-finger count seen
        self.seen = False       # any position sample captured
        self.ptr = None         # legacy ABS_X/Y: [sx, sy, lx, ly]
        self.slots = {}         # slot -> {"sx", "sy", "lx", "ly"}
        self.saw_phys = False   # a physical button was pressed during this gesture

    def note_phys_press(self):
        """A physical touchpad/mouse button was pressed during this gesture.

        libinput lets the physical button win: when the pad is physically
        clicked, any concurrent tap is NOT a separate click. So the tap is
        cancelled (otherwise a two-finger click would ring BOTH a left click
        from the physical button AND a right tap — the "gray+red" cascade).
        """
        self.saw_phys = True

    def key(self, code, value, now):
        """Handle an EV_KEY event. Returns True when the touch was released."""
        if code == ec.BTN_TOUCH:
            if value == 1:
                self.reset()
                self.t0 = now
                return False
            return True          # released -> the caller should finish()
        if code in self._TOOL and value == 1:
            self.fingers = max(self.fingers, self._TOOL[code])
        return False

    def abs(self, code, value):
        if code == ec.ABS_X:
            self.seen = True
            if self.ptr is None:
                self.ptr = [value, None, value, None]
            else:
                if self.ptr[0] is None:
                    self.ptr[0] = value
                self.ptr[2] = value
        elif code == ec.ABS_Y:
            self.seen = True
            if self.ptr is None:
                self.ptr = [None, value, None, value]
            else:
                if self.ptr[1] is None:
                    self.ptr[1] = value
                self.ptr[3] = value
        elif code == ec.ABS_MT_SLOT:
            self.cur = value
        elif code in (ec.ABS_MT_POSITION_X, ec.ABS_MT_POSITION_Y):
            self.seen = True
            s = self.slots.get(self.cur)
            if s is None:
                s = {"sx": None, "sy": None, "lx": None, "ly": None}
                self.slots[self.cur] = s
            if code == ec.ABS_MT_POSITION_X:
                if s["sx"] is None:
                    s["sx"] = value
                s["lx"] = value
            else:
                if s["sy"] is None:
                    s["sy"] = value
                s["ly"] = value

    def max_move(self):
        """Greatest displacement (mm) any tracked finger made during the gesture."""
        best = 0.0
        if self.ptr is not None:
            sx, sy, lx, ly = self.ptr
            if None not in (sx, sy, lx, ly):
                best = max(best, math.hypot((lx - sx) / self.rx, (ly - sy) / self.ry))
        for s in self.slots.values():
            if None not in (s["sx"], s["sy"], s["lx"], s["ly"]):
                best = max(best, math.hypot((s["lx"] - s["sx"]) / self.rx, (s["ly"] - s["sy"]) / self.ry))
        return best

    def finish(self, now, dwt_enabled, tap_enabled, key_until):
        """Return 'L'/'R' if this released gesture was a tap, else None."""
        if self.t0 is None or not self.seen:
            return None
        if self.saw_phys:
            # Physical button already rang for this gesture — cancel the tap.
            return None
        if now - self.t0 > TAP_MAX_S:
            return None
        if dwt_enabled and now < key_until:
            return None
        if not tap_enabled:
            return None
        if self.max_move() > TAP_MAX_MOVE_MM:
            return None
        nslots = sum(1 for s in self.slots.values()
                     if s["sx"] is not None or s["sy"] is not None)
        fingers = max(self.fingers, nslots) if nslots else self.fingers
        return "L" if fingers <= 1 else "R"


def click_loop():
    keyboards, mice, touchpads = classify_devices()

    fds = {dev.fd: dev for dev in mice}
    fds.update({dev.fd: dev for dev, _, _ in touchpads.values()})
    fds.update({dev.fd: dev for dev in keyboards})

    touch_end = set()       # fds whose BTN_TOUCH was released this batch
    trackers = {}           # fd -> TapTracker (reconstructs the tap decision)
    held_btn = {}           # (fd, evcode) -> effective button label ("L"/"R"/"M")
    dwt_enabled = option_bool("input:touchpad:disable-while-typing")
    tap_enabled = option_bool("input:touchpad:tap-to-click")
    clickfinger = option_bool("input:touchpad:clickfinger_behavior")
    key_until = 0.0
    last_cfg_check = 0.0
    held_mods = set()

    # --- multi-click buffer --------------------------------------------------
    # Holds the pending LEFT press so a double/triple click is emitted as ONE
    # event (D/T) instead of a burst of single clicks. The window considers a
    # double-click when a second press of the same button lands within the
    # double-click time AND within a small distance; we mirror that exactly
    # (dbl_s + DBL_PX) so the eye reacts once, the same as the window.
    dbl_s = DBL_MS / 1000.0
    buf = None  # {"t", "x", "y", "count"}

    def emit_click(code, x, y):
        print("C %d %d %s" % (x, y, code), flush=True)

    def commit_buf():
        """Emit whatever is pending right now (single/double/triple)."""
        nonlocal buf
        if not buf:
            return
        cnt = buf["count"]
        emit_click("L" if cnt == 1 else "D" if cnt == 2 else "T",
                   buf["x"], buf["y"])
        buf = None

    def flush_buf(now):
        """Emit the pending click once its double-click window has elapsed."""
        nonlocal buf
        if not buf:
            return
        if (now - buf["t"]) < dbl_s:
            return  # still inside the double-click window — wait for a 2nd press
        commit_buf()

    def note_press(code, x, y, now):
        nonlocal buf
        # Only LEFT clicks coalesce into double/triple; right/middle are
        # emitted immediately (a double right-click is rare and unusual).
        if code != ec.BTN_LEFT:
            emit_click("R" if code == ec.BTN_RIGHT else "M", x, y)
            return
        if (buf is not None and (now - buf["t"]) <= dbl_s
                and math.hypot(x - buf["x"], y - buf["y"]) <= DBL_PX):
            buf["count"] += 1
            buf["t"] = now
            buf["x"] = x
            buf["y"] = y
        else:
            # A NEW click: either too late or too far to be part of the pending
            # one. Commit the pending click as its own event NOW (it is a real
            # single/double the window saw) so it is never lost, then arm the
            # new buffer. This is the key to not dropping a quick click that
            # lands far away from a previous one.
            commit_buf()
            buf = {"t": now, "x": x, "y": y, "count": 1}

    MOD_ORDER = ["ctrl", "alt", "shift", "super"]

    def mods_str():
        return ",".join(m for m in MOD_ORDER if m in held_mods)

    while True:
        # Brief poll so a pending multi-click buffer flushes promptly and config
        # refreshes quickly; 50 ms is imperceptible for an input daemon.
        ready, _, _ = select.select(list(fds), [], [], 0.05)
        if not parent_alive():
            os._exit(0)
        now = time.monotonic()

        # refresh the DWT / tap-to-click config periodically (avoids a hyprctl
        # round-trip on every tap).
        if now - last_cfg_check > 3.0:
            dwt_enabled = option_bool("input:touchpad:disable-while-typing")
            tap_enabled = option_bool("input:touchpad:tap-to-click")
            clickfinger = option_bool("input:touchpad:clickfinger_behavior")
            last_cfg_check = now

        flush_buf(now)

        for fd in ready:
            try:
                events = fds[fd].read()
            except OSError:
                continue
            is_touch = fd in touchpads
            is_kbd = fd in {dev.fd for dev in keyboards}
            rx, ry = (touchpads[fd][1], touchpads[fd][2]) if is_touch else (31.0, 31.0)
            # Reconstruct taps from raw evdev per touchpad via a robust tracker
            # (MT slots + ABS_X/Y). We finish the gesture AFTER the whole batch
            # so tool-finger and ABS updates are applied first.
            tracker = trackers.get(fd)
            if is_touch and tracker is None:
                tracker = TapTracker(rx, ry)
                trackers[fd] = tracker
            ended = False
            for ev in events:
                if ev.type == ec.EV_KEY:
                    if is_kbd:
                        if ev.code in MOD_KEYS:
                            mod = MOD_KEYS[ev.code]
                            if ev.value == 1:
                                held_mods.add(mod)
                                print("M %s 1" % mod, flush=True)
                            else:
                                held_mods.discard(mod)
                                print("M %s 0" % mod, flush=True)
                            continue
                        # A real key press arms the typing-suppression window, but
                        # ONLY for "pure typing" (no modifier held). Holding
                        # Ctrl/Shift/Super is a shortcut, not typing — arming DWT
                        # there suppressed the following Ctrl+click / Shift+click
                        # that the window still receives (the "nothing" bug).
                        if ev.value == 1:
                            if not held_mods:
                                key_until = now + DWT_MS / 1000.0
                            name = key_display(ev.code)
                            if name:
                                print("K %s %s" % (name, mods_str()), flush=True)
                        continue
                    # Tap gesture state: BTN_TOUCH down/up + tool-finger count.
                    if is_touch and ev.code == ec.BTN_TOUCH:
                        ended = tracker.key(ec.BTN_TOUCH, ev.value, now)
                        continue
                    if is_touch and ev.code in TapTracker._TOOL:
                        tracker.key(ev.code, ev.value, now)
                        continue
                    # Physical touchpad/mouse button => a real click (press)
                    # with a hold-state, plus a green release ring on button-up.
                    if ev.code in (ec.BTN_LEFT, ec.BTN_RIGHT, ec.BTN_MIDDLE):
                        # Effective button: with clickfinger_behavior ON, a
                        # physical click made with 2 fingers down is a RIGHT
                        # click (the window does it, so the eye must too — this
                        # was the "two-finger click" that rang the wrong colour).
                        eff = ev.code
                        fingers_hint = max(tracker.fingers, len(tracker.slots)) if is_touch else 0
                        if (is_touch and clickfinger and ev.value == 1
                                and ev.code == ec.BTN_LEFT and fingers_hint >= 2):
                            eff = ec.BTN_RIGHT
                        btn = ("R" if eff == ec.BTN_RIGHT
                               else "L" if eff == ec.BTN_LEFT else "M")
                        if ev.value == 1:
                            # The system ignores touchpad physical buttons while
                            # disable-while-typing is active (the whole touchpad
                            # is disabled) — matching that is 1:1 with the window.
                            if is_touch and dwt_enabled and now < key_until:
                                continue
                            if is_touch:
                                # libinput lets the physical click win — cancel
                                # any tap racing with it (no extra ring).
                                tracker.note_phys_press()
                            held_btn[(fd, ev.code)] = btn
                            print("H %s 1" % btn, flush=True)
                            pos = query_cursor()
                            if pos:
                                note_press(eff, pos[0], pos[1], now)
                        else:
                            # Button-up: remember which effective button went down
                            # so the hold state is cleared with the SAME label.
                            btn = held_btn.pop((fd, ev.code), btn)
                            print("H %s 0" % btn, flush=True)
                            if is_touch and dwt_enabled and now < key_until:
                                continue
                            pos = query_cursor()
                            if pos:
                                print("C %d %d G" % (pos[0], pos[1]), flush=True)
                elif ev.type == ec.EV_ABS and is_touch:
                    tracker.abs(ev.code, ev.value)

            if ended:
                # Resolve the tap AFTER the whole batch (tool-finger + ABS are
                # already applied), so a multi-finger tap gives a single result
                # and a moving finger is correctly rejected as a tap.
                res = tracker.finish(now, dwt_enabled, tap_enabled, key_until)
                if DEBUG:
                    print("tapcand dur=%.0fms move=%.2fmm f=%d dwt=%s tap=%s -> %s" %
                          (1000 * (now - tracker.t0) if tracker.t0 else 0,
                           tracker.max_move(), tracker.fingers, dwt_enabled,
                           tap_enabled, res),
                          flush=True)
                if res:
                    pos = query_cursor()
                    if pos:
                        note_press(ec.BTN_LEFT if res == "L" else ec.BTN_RIGHT,
                                   pos[0], pos[1], tracker.t0)
                tracker.reset()


if __name__ == "__main__":
    if SOCK:
        threading.Thread(target=cursor_loop, daemon=True).start()
    click_loop()
