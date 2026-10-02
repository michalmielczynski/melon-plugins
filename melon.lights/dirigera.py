#!/usr/bin/env python3
"""Dirigera hub helper for the melon.lights omarchy plugin.

Talks to the IKEA DIRIGERA hub over its local HTTPS API (port 8443).
Reads the JWT token from (in priority order):
  1. $DIRIGERA_TOKEN
  2. ~/.config/ikea-dirigera-token.txt
  3. /tmp/dirigera_token.txt

Commands:
  devices         -> JSON array of lights (type == "light")
  set <id> <json> -> PATCH the given attributes, e.g. '{"isOn": true}'
  generate-token  -> PKCE flow; press the button on the hub when asked
"""

import base64
import hashlib
import json
import os
import random
import socket
import ssl
import string
import sys
import urllib.error
import urllib.request

HUB_IP = os.environ.get("DIRIGERA_IP", "192.168.0.38")
HUB_PORT = os.environ.get("DIRIGERA_PORT", "8443")
BASE = f"https://{HUB_IP}:{HUB_PORT}/v1"

TOKEN_FILES = [
    os.path.expanduser("~/.config/ikea-dirigera-token.txt"),
    "/tmp/dirigera_token.txt",
]

_CTX = ssl.create_default_context()
_CTX.check_hostname = False
_CTX.verify_mode = ssl.CERT_NONE


def load_token():
    token = os.environ.get("DIRIGERA_TOKEN", "").strip()
    if token:
        return token
    for path in TOKEN_FILES:
        try:
            with open(path, "r", encoding="utf-8") as handle:
                token = handle.read().strip()
        except OSError:
            continue
        if token:
            return token
    return ""


def request(method, path, body=None):
    token = load_token()
    if not token:
        raise RuntimeError(
            "No Dirigera token found. Put it in ~/.config/ikea-dirigera-token.txt "
            "or run 'generate-token' and press the button on the hub."
        )
    data = None
    headers = {"Authorization": "Bearer " + token}
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(BASE + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, context=_CTX, timeout=10) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as err:
        detail = err.read().decode("utf-8", "replace")[:300]
        raise RuntimeError(f"HTTP {err.code}: {detail}") from err
    except urllib.error.URLError as err:
        raise RuntimeError(f"Cannot reach {HUB_IP}:{HUB_PORT} ({err.reason})") from err
    return json.loads(raw) if raw else None


def fetch_lights():
    devices = request("GET", "/devices")
    lights = []
    for dev in devices:
        if dev.get("type") != "light":
            continue
        attrs = dev.get("attributes") or {}
        caps = (dev.get("capabilities") or {}).get("canReceive") or []
        room = dev.get("room") or {}
        ct_min = attrs.get("colorTemperatureMin")
        ct_max = attrs.get("colorTemperatureMax")
        if ct_min is None or ct_max is None:
            lo = hi = None
        else:
            lo = min(ct_min, ct_max)
            hi = max(ct_min, ct_max)
        lights.append({
            "id": dev.get("id"),
            "name": (attrs.get("customName") or attrs.get("model") or dev.get("id") or "").strip(),
            "room": (room.get("name") or "").strip(),
            "reachable": bool(dev.get("isReachable")),
            "isOn": bool(attrs.get("isOn")),
            "level": attrs.get("lightLevel"),
            "ct": attrs.get("colorTemperature"),
            "ctMin": lo,
            "ctMax": hi,
            "hue": attrs.get("colorHue"),
            "sat": attrs.get("colorSaturation"),
            "canLevel": "lightLevel" in caps,
            "canTemp": "colorTemperature" in caps,
            "canColor": "colorHue" in caps and "colorSaturation" in caps,
        })
    lights.sort(key=lambda x: (x["room"], x["name"]))
    return lights


def set_attributes(device_id, attrs):
    request("PATCH", f"/devices/{device_id}", [{"attributes": attrs}])
    return {"ok": True}


# ---- generate-token (PKCE, same flow as dirigera.hub.auth) ----

_ALPHABET = f"_-~.{string.ascii_letters}{string.digits}"


def _random_code(length=128):
    return "".join(random.choice(_ALPHABET) for _ in range(length))


def _code_challenge(verifier):
    digest = hashlib.sha256(verifier.encode()).digest()
    return base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")


def generate_token():
    verifier = _random_code()
    challenge = _code_challenge(verifier)
    authorize = f"{BASE}/oauth/authorize"
    params = (
        "audience=homesmart.local&response_type=code"
        f"&code_challenge={challenge}&code_challenge_method=S256"
    )
    try:
        with urllib.request.urlopen(f"{authorize}?{params}", context=_CTX, timeout=10) as resp:
            code = json.loads(resp.read())["code"]
    except Exception as err:  # noqa: BLE001
        raise RuntimeError(f"Error fetching authorization code: {err}") from err

    print(
        "Press the (Action) button on the Dirigera hub, then press ENTER...",
        file=sys.stderr,
    )
    sys.stderr.flush()
    input()

    data = (
        f"code={code}&name={socket.gethostname()}"
        "&grant_type=authorization_code"
        f"&code_verifier={verifier}"
    ).encode("utf-8")
    req = urllib.request.Request(
        f"{BASE}/oauth/token",
        data=data,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, context=_CTX, timeout=10) as resp:
            token = json.loads(resp.read())["access_token"]
    except Exception as err:  # noqa: BLE001
        raise RuntimeError(f"Error fetching token: {err}") from err

    out = os.path.expanduser("~/.config/ikea-dirigera-token.txt")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as handle:
        handle.write(token + "\n")
    os.chmod(out, 0o600)
    print(json.dumps({"ok": True, "tokenFile": out}))
    print(f"Token saved to {out}", file=sys.stderr)


def _usage():
    print("usage: dirigera.py devices | set <id> '<json>' | generate-token", file=sys.stderr)


def main(argv):
    if not argv:
        _usage()
        return 1
    cmd = argv[0]
    try:
        if cmd == "devices":
            print(json.dumps(fetch_lights(), ensure_ascii=False))
        elif cmd == "set":
            if len(argv) != 3:
                _usage()
                return 1
            attrs = json.loads(argv[2])
            print(json.dumps(set_attributes(argv[1], attrs)))
        elif cmd == "generate-token":
            generate_token()
        else:
            _usage()
            return 1
    except Exception as err:  # noqa: BLE001
        print(json.dumps({"ok": False, "error": str(err)}), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
