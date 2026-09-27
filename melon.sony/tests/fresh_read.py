#!/usr/bin/env python3
"""Weryfikacja zapisu w MDR: zapisz, zamknij sesje, otworz swieza i odczytaj.

Sesja, ktora pisala, czyta wlasny optymizm (biblioteka trzyma wlasna kopie),
wiec jedynym uczciwym testem jest reconnect. Uzycie:

    tests/fresh_read.py anc ambient
    tests/fresh_read.py eq bass
    tests/fresh_read.py dsee false
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


def start_helper():
    env = dict(os.environ, SONY_STATE_DIR=STATE)
    proc = subprocess.Popen([sys.executable, "-u", HELPER, "serve", "--mac", MAC],
                            cwd=ROOT, env=env, stdout=subprocess.DEVNULL,
                            stderr=subprocess.PIPE)
    deadline = time.time() + 40
    while time.time() < deadline:
        state = ask("state")
        if state and state.get("link") == "ready":
            time.sleep(2.5)          # dodatkowe GET-y dochodza po "ready"
            return proc, ask("state")
        if state and state.get("link") == "error":
            print("link error:", state.get("reason"))
        time.sleep(0.7)
    return proc, ask("state")


def ask(cmd, **extra):
    payload = {"cmd": cmd, **extra}
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(0.5)
            sock.connect(SOCK)
            sock.sendall((json.dumps(payload) + "\n").encode())
            deadline = time.time() + 2.0
            lines = []
            while time.time() < deadline:
                try:
                    chunk = sock.recv(65536)
                except socket.timeout:
                    break
                if not chunk:
                    break
                lines += chunk.decode("utf-8", "replace").splitlines()
                got = [json.loads(l) for l in lines if l.strip()]
                if cmd == "state" and got:
                    return got[0]
                if any(g.get("type") == "error" for g in got):
                    return [g for g in got if g.get("type") == "error"][-1]
                if time.time() > deadline - 1.2 and got:
                    return [g for g in got if g.get("type") == "state"][-1]
            return None
    except OSError:
        return None


def stop(proc):
    proc.send_signal(signal.SIGTERM)
    try:
        proc.wait(timeout=8)
    except subprocess.TimeoutExpired:
        proc.kill()


def digest(state):
    if not state:
        return "brak stanu"
    return json.dumps({
        "anc": state.get("anc"), "eq": state.get("eq"), "dsee": state.get("dsee"),
        "stc": state.get("stc"), "auto_pause": state.get("auto_pause"),
        "auto_off": state.get("auto_off"), "buds": state.get("buds"),
    }, ensure_ascii=False)


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "state"
    value = sys.argv[2] if len(sys.argv) > 2 else None
    proc, state = start_helper()
    print("przed :", digest(state))
    if cmd != "state":
        reply = ask(cmd, value=value) if value is not None else ask(cmd)
        print("write :", json.dumps(reply, ensure_ascii=False)[:200])
        time.sleep(1.5)
    stop(proc)
    time.sleep(2)
    proc, state = start_helper()
    print("po    :", digest(state))
    stop(proc)
    return 0


if __name__ == "__main__":
    sys.exit(main())
