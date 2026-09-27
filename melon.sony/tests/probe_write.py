#!/usr/bin/env python3
"""Diagnostyka jednej komendy: zapis, podglad ramek, swiezy odczyt.

    SONY_TRACE=1 tests/probe_write.py stc true
    tests/probe_write.py eq-band 0 3
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
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(0.5)
            sock.connect(SOCK)
            sock.sendall((json.dumps({"cmd": cmd, **extra}) + "\n").encode())
            deadline = time.time() + 3.0
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
                if last and time.time() > deadline - 2.0:
                    return last
            return last
    except OSError:
        return None


def start():
    global PROC
    env = dict(os.environ, SONY_STATE_DIR=STATE)
    PROC = subprocess.Popen([sys.executable, "-u", HELPER, "serve", "--mac", MAC],
                            cwd=ROOT, env=env, stdout=subprocess.DEVNULL)
    deadline = time.time() + 40
    while time.time() < deadline:
        st = ask("state")
        if st and st.get("link") == "ready":
            time.sleep(2.5)
            return ask("state")
        time.sleep(0.6)
    return ask("state")


def stop():
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


def main():
    cmd = sys.argv[1]
    args = sys.argv[2:]
    state = start()
    print("przed :", json.dumps({k: state.get(k) for k in
                                 ("stc", "dsee", "eq", "anc", "auto_pause", "auto_off")},
                                ensure_ascii=False))
    if cmd == "stc":
        reply = ask("stc", value=args[0] == "true")
    elif cmd == "dsee":
        reply = ask("dsee", value=args[0] == "true")
    elif cmd == "eq-band":
        bands = list(state.get("eq", {}).get("bands") or [0] * 6)
        bands[int(args[0])] = int(args[1])
        reply = ask("eq", preset="manual", bands=bands)
    elif cmd == "raw-stc":
        reply = ask("raw", value=[int(x, 0) for x in args[0].split(",")])
    elif cmd == "auto-off":
        reply = ask("auto-off", value=args[0])
    else:
        reply = ask(cmd, value=args[0] if args else None)
    print("write :", json.dumps(reply, ensure_ascii=False)[:160])
    time.sleep(2.0)
    stop()
    state = start()
    print("po    :", json.dumps({k: state.get(k) for k in
                                 ("stc", "dsee", "eq", "anc", "auto_pause", "auto_off")},
                                ensure_ascii=False))
    stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
