#!/usr/bin/env python3
"""Helper pluginu Omarchy melon.rekuperacja.

Rozmawia z mostkiem HTTP na Raspberry Pi (192.168.0.90:8770), ktory steruje
centrala Thessla Green AirPack Home 500h po Modbus RTU.

Mostek jest "hybrydowy": port RS485 zabiera na czas obslugi zadania i oddaje
ZenSystemConnect (aplikacja AirMobile w telefonie) po okresie bezczynnosci.

Uzycie:
  rekuperacja.py status [--fresh]     - pelny status (JSON)
  rekuperacja.py health               - stan mostka i wlasciciela portu
  rekuperacja.py on | off             - zalacz / wylacz centrale
  rekuperacja.py mode <auto|manual|temporary>
  rekuperacja.py season <summer|winter>
  rekuperacja.py airflow <10-100> [--manual]
  rekuperacja.py temp <10-45>
  rekuperacja.py special <none|hood|fireplace|airing_manual|open_windows|empty_house|...>
  rekuperacja.py comfort <on|off>     - on = KOMFORT, off = EKO
  rekuperacja.py bypass <on|off>
  rekuperacja.py bypass-user <1-3>
  rekuperacja.py bypass-min-temp <5-20>      - prog min. temp. zewnetrznej dla bypassu
  rekuperacja.py bypass-freecooling <15-30>  - prog temp. pokoju dla freecoolingu
  rekuperacja.py bypass-freeheating <15-30>  - prog temp. pokoju dla freeheatingu
  rekuperacja.py temporary-airflow <10-100>
  rekuperacja.py temporary-temp <10-45>
  rekuperacja.py release              - natychmiast oddaj port Zenowi

Konfiguracja: RK_BRIDGE (domyslnie http://192.168.0.90:8770),
RK_TIMEOUT (domyslnie 25 s). Wynik zawsze na stdout jako JSON.
"""

import json
import os
import sys
import urllib.error
import urllib.request

BRIDGE = os.environ.get("RK_BRIDGE", "http://192.168.0.90:8770")
TIMEOUT = float(os.environ.get("RK_TIMEOUT", "25"))

USAGE = __doc__.strip().split("Uzycie:")[-1].strip()


def request(method, path, payload=None):
    url = BRIDGE.rstrip("/") + path
    data = None
    headers = {}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            return json.loads(resp.read().decode("utf-8")), None
    except urllib.error.HTTPError as exc:
        try:
            body = json.loads(exc.read().decode("utf-8"))
        except Exception:
            body = {"error": "HTTP %s" % exc.code}
        return body, body.get("error", "HTTP %s" % exc.code)
    except Exception as exc:  # noqa: BLE001 - brak mostka to normalny stan
        return {"ok": False, "error": "Brak lacznosci z mostkiem: %s" % exc}, str(exc)


def write(path):
    """Zapis bez odczytu po zapisie (readback=0) - mostek odpowiada w ~0,2 s.

    Panel po takiej odpowiedzi sam dociaga swiezy status (patrz confirmTimer
    w BarWidget.qml), a do tego czasu pokazuje wartosci optymistyczne.
    """
    sep = "&" if "?" in path else "?"
    return request("POST", path + sep + "readback=0")


def fail(message):
    sys.stdout.write(json.dumps({"ok": False, "error": message}, ensure_ascii=False))
    sys.stdout.write("\n")
    return 1


def main(argv):
    if len(argv) < 2:
        return fail("podaj komende: %s" % USAGE.replace("\n", " "))

    cmd = argv[1]
    args = argv[2:]

    if cmd in ("status", "s"):
        fresh = "--fresh" in args or "-f" in args
        fast = "--fast" in args
        query = []
        if fresh:
            query.append("fresh=1")
        if fast:
            query.append("fast=1")
        payload, err = request(
            "GET", "/api/status" + ("?" + "&".join(query) if query else "")
        )
    elif cmd in ("health", "h"):
        payload, err = request("GET", "/api/health")
    elif cmd in ("on", "off"):
        payload, err = write("/api/%s" % cmd)
    elif cmd in ("mode", "season", "special", "comfort", "bypass"):
        if not args:
            return fail("%s: brak wartosci" % cmd)
        payload, err = write("/api/%s/%s" % (cmd, args[0]))
    elif cmd == "airflow":
        if not args:
            return fail("airflow: brak wartosci")
        suffix = "?mode=manual" if "--manual" in args else ""
        payload, err = write("/api/airflow/%s%s" % (args[0], suffix))
    elif cmd in ("temp", "temperature"):
        if not args:
            return fail("temp: brak wartosci")
        payload, err = write("/api/temperature/%s" % args[0])
    elif cmd == "bypass-user":
        if not args:
            return fail("bypass-user: brak wartosci")
        payload, err = write("/api/bypass/user/%s" % args[0])
    elif cmd == "temporary-airflow":
        if not args:
            return fail("temporary-airflow: brak wartosci")
        payload, err = request("POST", "/api/temporary", {"airflow": int(args[0])})
    elif cmd == "temporary-temp":
        if not args:
            return fail("temporary-temp: brak wartosci")
        payload, err = request("POST", "/api/temporary", {"temperature": float(args[0])})
    elif cmd == "bypass-min-temp":
        if not args:
            return fail("bypass-min-temp: brak wartosci")
        payload, err = write("/api/bypass/min-temp/%s" % args[0])
    elif cmd == "bypass-freecooling":
        if not args:
            return fail("bypass-freecooling: brak wartosci")
        payload, err = write("/api/bypass/freecooling/%s" % args[0])
    elif cmd == "bypass-freeheating":
        if not args:
            return fail("bypass-freeheating: brak wartosci")
        payload, err = write("/api/bypass/freeheating/%s" % args[0])
    elif cmd == "release":
        payload, err = request("POST", "/api/release")
    else:
        return fail("nieznana komenda: %s" % cmd)

    if payload is None:
        return fail(err or "brak odpowiedzi mostka")

    sys.stdout.write(json.dumps(payload, ensure_ascii=False))
    sys.stdout.write("\n")
    if err or payload.get("ok") is False or payload.get("online") is False:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
