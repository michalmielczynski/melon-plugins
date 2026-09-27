#!/usr/bin/env python3
"""Zapis + swieza sesja dla kazdej funkcji, potem powrot do stanu wyjsciowego.

Kazdy test: zapisz wartosc, zamknij sesje, otworz nowa, odczytaj. Sesja, ktora
pisala, czyta wlasny optymizm - tylko reconnect mowi prawde.
"""

import json
import os
import signal
import socket
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HELPER = os.path.join(ROOT, "sony-helper.py")
MAC = os.environ.get("SONY_MAC", "AC:80:0A:06:0E:89")
STATE = os.path.join(ROOT, ".state")
SOCK = os.path.join(STATE, "ctl.sock")
PROC = None


def ask(cmd, **extra):
    payload = {"cmd": cmd, **extra}
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(0.5)
            sock.connect(SOCK)
            sock.sendall((json.dumps(payload) + "\n").encode())
            deadline = time.time() + 2.5
            last = None
            while time.time() < deadline:
                try:
                    chunk = sock.recv(65536)
                except socket.timeout:
                    continue
                if not chunk:
                    break
                for line in chunk.decode("utf-8", "replace").splitlines():
                    if not line.strip():
                        continue
                    msg = json.loads(line)
                    if msg.get("type") == "error":
                        return msg
                    if msg.get("type") == "state":
                        last = msg
                if cmd == "state" and last:
                    return last
                if last and time.time() > deadline - 1.5:
                    return last
            return last
    except OSError:
        return None


def open_session():
    global PROC
    env = dict(os.environ, SONY_STATE_DIR=STATE)
    PROC = subprocess.Popen([sys.executable, "-u", HELPER, "serve", "--mac", MAC],
                            cwd=ROOT, env=env, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)
    deadline = time.time() + 40
    while time.time() < deadline:
        state = ask("state")
        if state and state.get("link") == "ready":
            time.sleep(2.5)
            return ask("state")
        time.sleep(0.6)
    return ask("state")


def close_session():
    global PROC
    if PROC is None:
        return
    PROC.send_signal(signal.SIGTERM)
    try:
        PROC.wait(timeout=8)
    except subprocess.TimeoutExpired:
        PROC.kill()
    PROC = None
    time.sleep(1.5)


def probes(state):
    return {
        "anc.mode": (state or {}).get("anc", {}).get("mode"),
        "eq.bands": (state or {}).get("eq", {}).get("bands"),
        "dsee": (state or {}).get("dsee"),
        "stc": (state or {}).get("stc"),
        "auto_pause": (state or {}).get("auto_pause"),
        "auto_off": (state or {}).get("auto_off"),
    }


PLAN = [
    ("anc", "ambient", "anc.mode", "ambient"),
    ("anc", "anc", "anc.mode", "anc"),
    ("auto-pause", False, "auto_pause", False),
    ("auto-pause", True, "auto_pause", True),
    ("stc", True, "stc", True),
    ("stc", False, "stc", False),
    ("dsee", False, "dsee", False),
    ("dsee", True, "dsee", True),
    ("eq", "manual", "eq.bands", None),          # pasma bez zmian - tylko sciezka zapisu
]


def main():
    state = open_session()
    before = probes(state)
    print("stan wyjsciowy:", json.dumps(before, ensure_ascii=False))
    results = []
    for cmd, value, field, expect in PLAN:
        if cmd == "eq":
            bands = (state or {}).get("eq", {}).get("bands") or [0] * 6
            reply = ask("eq", preset="manual", bands=bands)
        else:
            reply = ask(cmd, value=value)
        time.sleep(1.5)
        close_session()
        state = open_session()
        got = probes(state)
        ok = True if expect is None else got.get(field) == expect
        results.append((cmd, value, field, got.get(field), expect, ok, reply))
        print("%-10s %-8s -> %-11s %-22s %s" % (
            cmd, str(value), field, json.dumps(got.get(field)), "OK" if ok else "FAIL"))
    # powrot do stanu wyjsciowego
    for cmd, field in (("anc", "anc.mode"), ("auto-pause", "auto_pause"),
                       ("stc", "stc"), ("dsee", "dsee")):
        original = before.get(field)
        if original is None:
            continue
        ask(cmd, value=original)
        time.sleep(1.0)
    close_session()
    state = open_session()
    final = probes(state)
    print("stan koncowy:  ", json.dumps(final, ensure_ascii=False))
    close_session()
    failed = [r for r in results if not r[5]]
    print("WYNIK:", "wszystkie zapisy potwierdzone" if not failed else
          "%d niepotwierdzonych" % len(failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
