#!/usr/bin/env python3
"""Helper pluginu Omarchy melon.sony - obsluga sluchawek Sony WF-1000XM5.

Protokol MDR v2 po RFCOMM (UUID 956c7b26-d49a-4ba8-b03f-b17d393cb6e2),
sesje otwiera BlueZ (Profile1), bo to on robi SDP i podaje nam gniazdo.

Dwie role w jednym procesie:
  * serwer  - trzyma jedna sesje MDR, publikuje stan jako linie JSON na
              stdout (czyta je Panel.qml) i na gniazdku unixowym (sonyctl),
  * klient  - `sony-helper.py ctl <komenda>` wysyla komende do serwera.

Komendy przyjmowane jako linie JSON na stdin albo na gniazdku:
  {"cmd":"anc","value":"anc|ambient|off"}
  {"cmd":"anc-level","value":1..20}
  {"cmd":"anc-focus","value":true|false}
  {"cmd":"eq","preset":"off|bright|...","bands":[-10..10] x6}
  {"cmd":"dsee","value":true|false}
  {"cmd":"stc","value":true|false}
  {"cmd":"auto-pause","value":true|false}
  {"cmd":"auto-off","value":"5|15|30|60|180|removed|off"}
  {"cmd":"power-off"}
  {"cmd":"audio-profile","value":"a2dp|headset"}
  {"cmd":"refresh"}
"""

import argparse
import glob
import json
import os
import signal
import socket
import subprocess
import sys
import time

try:
    import dbus
    import dbus.service
    import dbus.mainloop.glib
    from gi.repository import GLib
    try:
        from gi.repository import GLibUnix
    except ImportError:  # starsze PyGObject
        GLibUnix = None
except ImportError as exc:  # pragma: no cover - zaleznosci systemowe
    sys.stderr.write("melon.sony: brak python-dbus/python-gobject: %s\n" % exc)
    sys.exit(2)

ADAPTER = os.environ.get("SONY_ADAPTER", "hci0")
DEFAULT_MAC = os.environ.get("SONY_MAC", "")
SONY_UUID = "956c7b26-d49a-4ba8-b03f-b17d393cb6e2"

HEADER, TRAILER, ESCAPE, ESC_MASK = 0x3E, 0x3C, 0x3D, 0xEF
MT_ACK, MT_CMD1, MT_CMD2 = 0x01, 0x0C, 0x0E

# --- NCASM (ANC / ambient) -------------------------------------------------
ASM_BY_FUNC = [(0x6D, 0x19), (0x6B, 0x17), (0x68, 0x15), (0x67, 0x22), (0x66, 0x21)]
# --- EQ --------------------------------------------------------------------
EQ_BY_FUNC = [(0x50, 0x00), (0x51, 0x01), (0x52, 0x02), (0x57, 0x04), (0x55, 0x31)]
EQ_BANDS = 6          # clear bass + 5 pasm
EQ_OFFSET = 10        # bajt na drucie = poziom + 10
EQ_PRESETS = {"off": 0x00, "bright": 0x10, "excited": 0x11, "mellow": 0x12,
              "relaxed": 0x13, "vocal": 0x14, "treble": 0x15, "bass": 0x16,
              "speech": 0x17, "manual": 0xA0, "custom1": 0xA1, "custom2": 0xA2}
EQ_NAMES = {v: k for k, v in EQ_PRESETS.items()}
# --- POWER -----------------------------------------------------------------
PWR_UNKNOWN, PWR_CHARGING, PWR_CHARGED, PWR_NOT_CHARGING = 0, 1, 2, 3
AUTO_OFF_VALUES = {"5": 0x00, "15": 0x04, "30": 0x01, "60": 0x02,
                   "180": 0x03, "removed": 0x10, "off": 0x11}
AUTO_OFF_NAMES = {v: k for k, v in AUTO_OFF_VALUES.items()}
ON, OFF = 0x00, 0x01   # OnOffSettingValue

STATE_DIR = os.environ.get("SONY_STATE_DIR") or os.path.join(
    os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "melon-sony")
SOCK_PATH = os.path.join(STATE_DIR, "ctl.sock")


TRACE = os.environ.get("SONY_TRACE") == "1"


def trace(direction, mtype, payload):
    """Podglad ramek na drut (SONY_TRACE=1) - do diagnozy zapisow."""
    if TRACE:
        sys.stderr.write("%s t=%#04x %s\n" % (direction, mtype, bytes(payload).hex(" ")))
        sys.stderr.flush()


def esc(bs):
    out = bytearray()
    for b in bs:
        if b in (HEADER, TRAILER, ESCAPE):
            out += bytes((ESCAPE, b & ESC_MASK))
        else:
            out.append(b)
    return bytes(out)


def build_frame(mtype, seq, payload):
    body = bytes((mtype, seq)) + len(payload).to_bytes(4, "big") + bytes(payload)
    return bytes((HEADER,)) + esc(body) + esc((sum(body) & 0xFF,)) + bytes((TRAILER,))


def parse_frame(frame):
    """Zwraca (mtype, seq, payload) albo None gdy ramka jest uszkodzona."""
    raw = bytearray()
    i = 1
    while i < len(frame) - 1:
        b = frame[i]
        if b == ESCAPE:
            i += 1
            b = frame[i] | (~ESC_MASK & 0xFF)
        raw.append(b)
        i += 1
    if len(raw) < 7 or sum(raw[:-1]) & 0xFF != raw[-1]:
        return None
    return raw[0], raw[1], bytes(raw[6:-1])


def discover_sony(bus, adapter=None):
    """Sluchawki Sony znalezione po usludze MDR (a nie po adresie).

    Zwraca liste dictow, najpierw podlaczone, potem sparowane.
    """
    try:
        manager = dbus.Interface(bus.get_object("org.bluez", "/"),
                                 "org.freedesktop.DBus.ObjectManager")
        objects = manager.GetManagedObjects()
    except dbus.DBusException:
        return []
    found = []
    for path, interfaces in objects.items():
        device = interfaces.get("org.bluez.Device1")
        if device is None:
            continue
        if adapter and ("/" + adapter + "/") not in path:
            continue
        uuids = [str(u).lower() for u in device.get("UUIDs", [])]
        if SONY_UUID not in uuids:
            continue
        found.append({
            "path": str(path),
            "address": str(device.get("Address", "")),
            "name": str(device.get("Alias") or device.get("Name") or "Sony"),
            "connected": bool(device.get("Connected", False)),
            "paired": bool(device.get("Paired", False)),
        })
    found.sort(key=lambda d: (d["connected"], d["paired"]))
    return found


def pactl(*args, timeout=5):
    try:
        return subprocess.run(["pactl", *args], capture_output=True, text=True,
                              timeout=timeout).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def find_node(kind, prefix):
    for line in pactl("list", "short", kind).splitlines():
        parts = line.split("\t")
        if len(parts) > 1 and parts[1].startswith(prefix) and "monitor" not in parts[1]:
            return parts[1]
    return None


def ldac_quality_setting():
    """Jakosc LDAC ustawiona w WirePlumber (hq=990, sq=660, mq=330 kbps)."""
    for path in sorted(glob.glob(os.path.expanduser(
            "~/.config/wireplumber/wireplumber.conf.d/*.conf"))) + \
            sorted(glob.glob("/etc/wireplumber/wireplumber.conf.d/*.conf")):
        try:
            with open(path, "r", encoding="utf-8") as fh:
                for line in fh:
                    if "ldac.quality" in line and "=" in line:
                        return line.split("=", 1)[1].strip().strip('"').strip()
        except OSError:
            continue
    return ""


class Session(dbus.service.Object):
    """Jedna sesja MDR na sluchawkach - cala logika protokolu."""

    PATH = "/melon/sony/profile"

    def __init__(self, helper, bus):
        super().__init__(bus, self.PATH)
        self.helper = helper
        self.bus = bus
        self.fd = None
        self.buf = b""
        self.seq = 0
        self.stage = None
        self.txq = []
        self.tx_busy = False
        self.tx_timer = None
        self.tx_retry = 0
        self.last_tx = None
        self.stage_timer = None
        self.stage_retries = 0
        self.stage_payload = None
        self.asm = None
        self.eq_type = None
        self.registered = False
        self.dev_path = None
        self.features = {}

    # --- rejestracja profilu w BlueZ ---
    def register(self):
        if self.registered:
            return True
        try:
            dbus.Interface(self.bus.get_object("org.bluez", "/org/bluez"),
                           "org.bluez.ProfileManager1").RegisterProfile(
                self.PATH, SONY_UUID,
                {"Name": "melon.sony", "Role": "client",
                 "AutoConnect": dbus.Boolean(True)})
            self.registered = True
            return True
        except dbus.DBusException as exc:
            self.helper.emit("error", where="profile",
                             message=str(exc.get_dbus_message()))
            return False

    # --- Profile1 ---
    @dbus.service.method("org.bluez.Profile1", in_signature="oha{sv}")
    def NewConnection(self, path, fd, props):
        self.take_fd(fd.take())

    @dbus.service.method("org.bluez.Profile1", in_signature="o")
    def RequestDisconnection(self, path):
        self.close("requested")

    @dbus.service.method("org.bluez.Profile1")
    def Release(self):
        self.close("released")

    # --- sesja ---
    def take_fd(self, fd):
        self.close_fd()
        self.fd = fd
        try:
            os.set_blocking(self.fd, False)
        except OSError:
            pass
        self.buf = b""
        self.seq = 0
        self.txq = []
        self.tx_busy = False
        self.features = {}
        GLib.io_add_watch(self.fd, GLib.IO_IN | GLib.IO_HUP, self.on_readable)
        self.helper.set_link("handshake", "Sesja otwarta, uzgadniam protokol")
        self.request("proto", [0x00, 0x00], 4)

    def close_fd(self):
        if self.fd is not None:
            try:
                os.close(self.fd)
            except OSError:
                pass
        self.fd = None

    def close(self, reason):
        self.close_fd()
        self.stage = None
        if self.tx_timer:
            GLib.source_remove(self.tx_timer)
            self.tx_timer = None
        if self.stage_timer:
            GLib.source_remove(self.stage_timer)
            self.stage_timer = None
        self.tx_busy = False
        self.txq = []
        self.helper.set_link("idle", reason)

    # --- wysylka: jedna ramka w locie, ACK zwalnia kolejke ---
    def send(self, payload, mtype=MT_CMD1):
        if self.fd is None:
            return False
        seq, self.seq = self.seq, 1 - self.seq
        frame = build_frame(mtype, seq, payload)
        self.txq.append((frame, payload, mtype, seq, 0))
        self.pump()
        return True

    def ack(self, seq):
        if self.fd is None:
            return
        try:
            os.write(self.fd, build_frame(MT_ACK, 1 - seq, b""))
        except OSError:
            pass

    def pump(self):
        if self.tx_busy or not self.txq or self.fd is None:
            return
        frame, payload, mtype, seq, tries = self.txq[0]
        try:
            os.write(self.fd, frame)
            trace("TX", mtype, payload)
        except OSError as exc:
            self.helper.emit("error", where="tx", message=str(exc))
            self.close("Zapis nieudany")
            return
        self.tx_busy = True
        self.last_tx = (payload, mtype)
        if self.tx_timer:
            GLib.source_remove(self.tx_timer)
        self.tx_timer = GLib.timeout_add(500, self.tx_timeout)

    def tx_timeout(self):
        self.tx_timer = None
        if not self.txq:
            self.tx_busy = False
            return False
        frame, payload, mtype, seq, tries = self.txq[0]
        if tries >= 3:
            self.txq.pop(0)
            self.tx_busy = False
            self.helper.emit("error", where="ack", message="Brak potwierdzenia")
            self.pump()
            return False
        # retransmisja z odwroconym bitem sekwencji (tak robi libmdr)
        self.txq[0] = (build_frame(mtype, 1 - seq, payload), payload, mtype, 1 - seq, tries + 1)
        self.tx_busy = False
        self.pump()
        return False

    def acked(self):
        if self.tx_timer:
            GLib.source_remove(self.tx_timer)
            self.tx_timer = None
        if self.txq:
            self.txq.pop(0)
        self.tx_busy = False
        self.pump()

    # --- odbior ---
    def on_readable(self, fd, condition):
        try:
            data = os.read(fd, 4096)
        except BlockingIOError:
            return True
        except OSError:
            data = b""
        if not data:
            self.close("Sluchawki zamknely sesje")
            return False
        self.buf += data
        while True:
            start = self.buf.find(bytes((HEADER,)))
            if start < 0:
                self.buf = b""
                break
            end = self.buf.find(bytes((TRAILER,)), start + 1)
            if end < 0:
                self.buf = self.buf[start:]
                break
            frame, self.buf = self.buf[start:end + 1], self.buf[end + 1:]
            parsed = parse_frame(frame)
            if not parsed:
                continue
            mtype, seq, payload = parsed
            trace("RX", mtype, payload)
            if mtype == MT_ACK:
                self.acked()
                continue
            if mtype in (MT_CMD1, MT_CMD2):
                self.ack(seq)
            if payload:
                self.dispatch(payload)
        return True

    # --- sekwencja startowa ---
    def request(self, stage, payload, retries=4):
        self.stage = stage
        self.stage_payload = payload
        self.stage_retries = retries
        if self.stage_timer:
            GLib.source_remove(self.stage_timer)
        self.stage_timer = GLib.timeout_add_seconds(3, self.stage_retry)
        self.send(list(payload))

    def stage_retry(self):
        if self.stage in (None, "ready"):
            self.stage_timer = None
            return False
        self.stage_retries -= 1
        if self.stage_retries <= 0:
            self.stage_timer = None
            self.helper.set_link("error", "Sluchawki nie odpowiadaja (%s)" % self.stage)
            return False
        self.send(list(self.stage_payload))
        return True

    def dispatch(self, payload):
        op = payload[0]
        if op in (0x01, 0x05) and self.stage == "proto":
            self.request("support", [0x06, 0x00], 4)
        elif op == 0x07 and self.stage == "support":
            count = payload[2] if len(payload) > 2 else 0
            funcs = {payload[3 + i * 2] for i in range(count) if 3 + i * 2 < len(payload)}
            self.plan(funcs)
            if self.asm is None:
                self.helper.set_link("error", "Brak funkcji ANC/ASM")
                self.stage = None
                return
            self.request("ncasm", [0x66, self.asm], 4)
        elif op in (0x67, 0x69):                      # NCASM RET / NTFY
            self.handle_ncasm(payload)
        elif op in (0x23, 0x25):                      # POWER RET / NTFY (bateria)
            self.handle_battery(payload)
        elif op in (0x27, 0x29):                      # POWER RET / NTFY (param)
            self.handle_power_param(payload)
        elif op in (0x57, 0x59):                      # EQEBB RET / NTFY
            self.handle_eq(payload)
        elif op in (0xE7, 0xE9):                      # AUDIO RET / NTFY (DSEE)
            self.handle_audio(payload)
        elif op in (0xF7, 0xF9):                      # SYSTEM RET / NTFY
            self.handle_system(payload)
        elif op in (0xD3, 0xD5, 0xD7, 0xD9):          # GENERAL_SETTING - ignorujemy
            pass

    def plan(self, funcs):
        self.asm = next((a for f, a in ASM_BY_FUNC if f in funcs), None)
        self.eq_type = next((e for f, e in EQ_BY_FUNC if f in funcs), None)

    def probe_extras(self):
        """GET-y dodatkow: odpowiedz = funkcja istnieje (brak odpowiedzi = nie)."""
        sends = [[0x22, 0x01], [0x22, 0x02], [0x26, 0x05], [0xE6, 0x01], [0xF6, 0x01], [0xF6, 0x0C]]
        if self.eq_type is not None:
            sends.append([0x56, self.eq_type])
        for delay, payload in enumerate(sends):
            GLib.timeout_add(250 * delay, self._deferred_send, payload)
        # Pojedynczy GET potrafi zginac - powtorka po 4 s domyka brakujace funkcje.
        GLib.timeout_add(4000, self._reprobe)

    def _reprobe(self):
        if self.stage != "ready":
            return False
        missing = [p for key, p in (
            ("dsee", [0xE6, 0x01]), ("stc", [0xF6, 0x0C]),
            ("auto_pause", [0xF6, 0x01]), ("auto_off", [0x26, 0x05])) if not self.helper.features.get(key)]
        for delay, payload in enumerate(missing):
            GLib.timeout_add(250 * delay, self._deferred_send, payload)
        return False

    def _deferred_send(self, payload):
        if self.fd is not None:
            self.send(list(payload))
        return False

    # --- parsery ---
    def handle_battery(self, p):
        if len(p) < 4:
            return
        kind = p[1]
        level = lambda v: max(0, min(100, int(v)))
        if kind in (0x01, 0x09):
            if len(p) < 6:
                return
            if p[2] > 0:
                self.helper.buds["left"] = level(p[2])
                self.helper.buds["left_charging"] = p[3] in (PWR_CHARGING, PWR_CHARGED)
            if p[4] > 0:
                self.helper.buds["right"] = level(p[4])
                self.helper.buds["right_charging"] = p[5] in (PWR_CHARGING, PWR_CHARGED)
            self.helper.features["bud_battery"] = True
        elif kind in (0x02, 0x0A):
            self.helper.buds["case"] = level(p[2])
            self.helper.buds["case_charging"] = p[3] in (PWR_CHARGING, PWR_CHARGED)
        else:
            return
        self.helper.publish()

    def handle_power_param(self, p):
        if len(p) >= 4 and p[1] == 0x05:               # auto power off z detekcja noszenia
            self.helper.features["auto_off"] = True
            self.helper.auto_off = AUTO_OFF_NAMES.get(p[2], "?")
            self.helper.publish()

    def handle_audio(self, p):
        if len(p) > 1 and p[1] == 0x01:                # DSEE
            self.helper.features["dsee"] = True
            if len(p) == 3 and p[2] in (0, 1):
                self.helper.dsee = bool(p[2])
                self.helper.publish()

    def handle_system(self, p):
        if len(p) < 3:
            return
        if p[1] == 0x0C:                               # speak-to-chat
            self.helper.features["stc"] = True
            if p[2] in (0, 1):
                self.helper.stc = (p[2] == ON)
                self.helper.publish()
        elif p[1] == 0x01:                             # auto-pause (playback control by wearing)
            self.helper.features["auto_pause"] = True
            if p[2] in (0, 1):
                self.helper.auto_pause = (p[2] == ON)
                self.helper.publish()

    def handle_eq(self, p):
        if len(p) < 4 + EQ_BANDS or p[1] != self.eq_type or p[3] != EQ_BANDS:
            return
        self.helper.features["eq"] = True
        preset = EQ_NAMES.get(p[2])
        if preset is None:
            return
        self.helper.eq_preset = preset
        self.helper.eq_bands = [p[4 + i] - EQ_OFFSET for i in range(EQ_BANDS)]
        self.helper.publish()

    def handle_ncasm(self, p):
        if not 6 <= len(p) <= 9 or p[1] != self.asm:
            return
        no_nc = self.asm in (0x21, 0x22)
        wind = self.asm == 0x15
        na = self.asm == 0x19
        if p[3] == 0x00:
            mode = "off"
        elif wind and p[5] in (0x03, 0x05):
            mode = "wind"
        elif no_nc:
            mode = "ambient"
        else:
            mode = "anc" if p[4] == 0x00 else "ambient"
        i = len(p) - (4 if na else 2)
        if i + 1 < len(p):
            self.helper.anc_focus = (p[i] == 0x01)
            level = p[i + 1]
            self.helper.anc_level = level if 0 <= level <= 20 else 10
        if na and i + 3 < len(p):
            self.helper.na_extra = [p[i + 2] if p[i + 2] in (0, 1) else 0,
                                    p[i + 3] if p[i + 3] in (0, 1, 2) else 0]
        self.helper.anc_mode = mode
        if self.stage == "ncasm":
            self.stage = "ready"
            if self.stage_timer:
                GLib.source_remove(self.stage_timer)
                self.stage_timer = None
            self.helper.set_link("ready", "")
            self.probe_extras()
        self.helper.publish()

    # --- otwarcie sesji przez BlueZ ---
    def dial(self, mac):
        if self.fd is not None:
            return
        try:
            dev = self.helper.device_iface()
            dev.ConnectProfile(SONY_UUID, timeout=25,
                               reply_handler=lambda: None,
                               error_handler=self.dial_failed)
        except dbus.DBusException as exc:
            self.dial_failed(exc)

    def dial_failed(self, exc):
        message = getattr(exc, "get_dbus_message", lambda: str(exc))()
        self.helper.dial_error(message)

    # --- komendy ---
    def set_anc(self, mode):
        if self.stage != "ready":
            return False
        no_nc = self.asm in (0x21, 0x22)
        wind = self.asm == 0x15
        na = self.asm == 0x19
        payload = [0x68, self.asm, 0x01, 0x00 if mode == "off" else 0x01]
        if not no_nc:
            payload.append(0x01 if mode == "ambient" else 0x00)
        if wind:
            payload.append(0x03 if mode == "wind" else 0x02)
        payload += [0x01 if self.helper.anc_focus else 0x00, max(1, self.helper.anc_level)]
        if na:
            payload += self.helper.na_extra
        self.helper.anc_mode = mode
        self.helper.publish()
        return self.send(payload)

    def set_anc_level(self, level):
        # poziom zmieniamy w trybie ambient - w ANC nie ma czego ustawiac
        mode = self.helper.anc_mode if self.helper.anc_mode in ("ambient", "wind") else None
        self.helper.anc_level = max(1, min(20, int(level)))
        if mode is None:
            self.helper.publish()
            return True
        return self.set_anc(mode)

    def set_anc_focus(self, focus):
        self.helper.anc_focus = bool(focus)
        if self.helper.anc_mode in ("ambient", "wind"):
            return self.set_anc(self.helper.anc_mode)
        self.helper.publish()
        return True

    def set_eq(self, preset=None, bands=None):
        if self.stage != "ready" or self.eq_type is None:
            return False
        if bands is not None:
            bands = [max(-EQ_OFFSET, min(EQ_OFFSET, int(b))) for b in bands][:EQ_BANDS]
            while len(bands) < EQ_BANDS:
                bands.append(0)
            self.helper.eq_bands = bands
            self.helper.eq_preset = preset or "manual"
            code = EQ_PRESETS.get(self.helper.eq_preset, 0xA0)
            self.helper.publish()
            return self.send([0x58, self.eq_type, code, EQ_BANDS] + [b + EQ_OFFSET for b in bands])
        if preset is None or preset not in EQ_PRESETS:
            return False
        # preset i pasma to jedna wiadomosc - zawsze odsylamy oba
        self.helper.eq_preset = preset
        self.helper.publish()
        return self.send([0x58, self.eq_type, EQ_PRESETS[preset], EQ_BANDS] +
                         [b + EQ_OFFSET for b in self.helper.eq_bands])

    def set_dsee(self, value):
        if self.stage != "ready":
            return False
        self.helper.dsee = bool(value)
        self.helper.publish()
        return self.send([0xE8, 0x01, 0x01 if value else 0x00])

    def set_stc(self, value):
        if self.stage != "ready":
            return False
        self.helper.stc = bool(value)
        self.helper.publish()
        return self.send([0xF8, 0x0C, ON if value else OFF, 0x01])

    def set_auto_pause(self, value):
        if self.stage != "ready":
            return False
        self.helper.auto_pause = bool(value)
        self.helper.publish()
        return self.send([0xF8, 0x01, ON if value else OFF, 0x01])

    def set_auto_off(self, value):
        if self.stage != "ready" or value not in AUTO_OFF_VALUES:
            return False
        code = AUTO_OFF_VALUES[value]
        self.helper.auto_off = value
        self.helper.publish()
        return self.send([0x28, 0x05, code, code])

    def power_off(self):
        if self.stage != "ready":
            return False
        return self.send([0x24, 0x03, ON])


class Helper:
    def __init__(self, mac=None, adapter=None):
        self.mac = mac
        self.prefer_mac = (mac or "").upper()
        self.adapter = adapter
        self.dev_path = None
        self.bus = None
        self.session = None
        self.clients = []
        self.listener = None
        self.device = None
        self.link = "idle"
        self.reason = ""
        self.buds = {"left": None, "right": None, "case": None,
                     "left_charging": False, "right_charging": False,
                     "case_charging": False}
        self.anc_mode = "unknown"
        self.anc_level = 10
        self.anc_focus = False
        self.na_extra = [0x00, 0x00]
        self.eq_preset = "off"
        self.eq_bands = [0] * EQ_BANDS
        self.dsee = None
        self.stc = None
        self.auto_pause = None
        self.auto_off = None
        self.features = {}
        self.bluez_battery = None
        self.name = "WF-1000XM5"
        self.connected = False
        self.dial_timer = None
        self.dial_tries = 0
        self.audio = {"profile": "", "codec": "", "sink": "", "source": "", "ldac": ""}

    # --- komendy z stdin / gniazdka ---
    def handle(self, line):
        try:
            cmd = json.loads(line)
        except ValueError:
            self.emit("error", where="cmd", message="Niepoprawny JSON")
            return
        name = cmd.get("cmd")
        value = cmd.get("value")
        session = self.session
        if name == "state":
            self.emit("state", **self.snapshot())
            return
        if name == "refresh":
            self.refresh_device()
            self.refresh_audio()
            self.publish()
            return
        actions = {
            "anc": lambda: session.set_anc(value),
            "anc-level": lambda: session.set_anc_level(int(value)),
            "anc-focus": lambda: session.set_anc_focus(bool(value)),
            "eq": lambda: session.set_eq(cmd.get("preset"), cmd.get("bands")),
            "dsee": lambda: session.set_dsee(bool(value)),
            "stc": lambda: session.set_stc(bool(value)),
            "auto-pause": lambda: session.set_auto_pause(bool(value)),
            "auto-off": lambda: session.set_auto_off(str(value)),
            "power-off": lambda: session.power_off(),
            "raw": lambda: session.send([int(b) for b in value]),
            "audio-profile": lambda: self.set_audio_profile(value),
        }
        action = actions.get(name)
        if action is None:
            self.emit("error", where=str(name), message="Nieznana komenda")
            return
        try:
            ok = action()
        except (TypeError, ValueError) as exc:
            self.emit("error", where=str(name), message="Zly argument: %s" % exc)
            return
        if not ok:
            self.emit("error", where=str(name),
                      message="Sesja kontrolna nie jest gotowa" if session.stage != "ready"
                      else "Sluchawki nie przyjmuja tej funkcji")

    def set_audio_profile(self, value):
        """a2dp = najwyzsza jakosc (LDAC), headset = mikrofon (HFP, gorszy dzwiek)."""
        card = "bluez_card." + self.mac.replace(":", "_")
        profile = "a2dp-sink" if value in ("a2dp", "a2dp-sink", None) else "headset-head-unit"
        if value == "headset-msbc":
            profile = "headset-head-unit-msbc"
        pactl("set-card-profile", card, profile)
        GLib.timeout_add(700, lambda: (self.refresh_audio(), self.publish(), False)[2])
        return True

    def dial_error(self, message):
        self.set_link("error", "Sesja kontrolna: %s" % message)
        self.schedule_retry(20 if self.dial_tries < 6 else 120)

    def schedule_retry(self, delay):
        self.dial_tries += 1
        if self.dial_timer:
            GLib.source_remove(self.dial_timer)
        self.dial_timer = GLib.timeout_add_seconds(delay, self.retry_dial)

    def retry_dial(self):
        self.dial_timer = None
        if not self.connected or self.session.fd is not None:
            return False
        self.set_link("dialing", "Ponawiam otwarcie sesji kontrolnej")
        self.session.dial(self.mac)
        return False

    # --- wyjscie ---
    def emit(self, kind, **fields):
        line = json.dumps({"type": kind, **fields}, ensure_ascii=False)
        sys.stdout.write(line + "\n")
        sys.stdout.flush()
        dead = []
        for client in self.clients:
            try:
                client.sendall((line + "\n").encode("utf-8"))
            except OSError:
                dead.append(client)
        for client in dead:
            self.clients.remove(client)

    def publish(self):
        self.emit("state", **self.snapshot())

    def set_link(self, link, reason):
        self.link = link
        self.reason = reason
        self.emit("link", link=link, reason=reason)
        self.publish()

    def snapshot(self):
        return {
            "name": self.name, "address": self.mac, "connected": self.connected,
            "link": self.link, "reason": self.reason,
            "buds": self.buds, "bluez_battery": self.bluez_battery,
            "anc": {"mode": self.anc_mode, "level": self.anc_level, "focus": self.anc_focus},
            "eq": {"preset": self.eq_preset, "bands": self.eq_bands},
            "dsee": self.dsee, "stc": self.stc, "auto_pause": self.auto_pause,
            "auto_off": self.auto_off, "features": self.features,
            "audio": self.audio,
        }

    # --- gniazdko dla sonyctl ---
    def start_socket(self):
        try:
            os.makedirs(STATE_DIR, exist_ok=True)
            try:
                os.unlink(SOCK_PATH)
            except OSError:
                pass
            self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.listener.bind(SOCK_PATH)
            os.chmod(SOCK_PATH, 0o600)
            self.listener.listen(4)
            self.listener.setblocking(False)
            GLib.io_add_watch(self.listener, GLib.IO_IN, self.on_client)
        except OSError as exc:
            # bez gniazdka zostaje stdout (Panel.qml) - to nie jest blad krytyczny
            self.listener = None
            self.emit("error", where="socket", message=str(exc))

    def on_client(self, listener, condition):
        try:
            conn, _ = listener.accept()
        except OSError:
            return True
        conn.setblocking(False)
        self.clients.append(conn)
        conn.sendall((json.dumps({"type": "state", **self.snapshot()},
                                 ensure_ascii=False) + "\n").encode("utf-8"))
        GLib.io_add_watch(conn, GLib.IO_IN | GLib.IO_HUP, self.on_client_data, conn)
        return True

    def on_client_data(self, conn, condition, *_):
        try:
            data = conn.recv(4096)
        except BlockingIOError:
            return True
        except OSError:
            data = b""
        if not data:
            if conn in self.clients:
                self.clients.remove(conn)
            try:
                conn.close()
            except OSError:
                pass
            return False
        for line in data.decode("utf-8", "replace").splitlines():
            line = line.strip()
            if line:
                self.handle(line)
        return True

    # --- BlueZ ---
    def start_bluez(self):
        self.bus = dbus.SystemBus()
        self.session = Session(self, self.bus)
        self.session.register()
        self.bus.add_signal_receiver(self.on_props, dbus_interface="org.freedesktop.DBus.Properties",
                                     signal_name="PropertiesChanged")
        self.bus.add_signal_receiver(self.on_interfaces, dbus_interface="org.freedesktop.DBus.ObjectManager",
                                     signal_name="InterfacesAdded")
        self.retarget()
        GLib.timeout_add_seconds(15, self.retarget_tick)

    def retarget(self):
        """Wybierz sluchawki (podlaczone przed sparowanymi) i pilnuj podlaczenia."""
        devices = discover_sony(self.bus, self.adapter)
        if self.prefer_mac:
            devices = [d for d in devices if d["address"].upper() == self.prefer_mac]
        if not devices:
            self.dev_path = None
            self.connected = False
            if self.session.fd is not None:
                self.session.close("Sluchawki zniknely")
            self.set_link("idle", "Nie widzę słuchawek Sony (MDR)")
            return False
        best = devices[0]
        if best["path"] != self.dev_path:
            self.session.close("Zmiana słuchawek")
            self.dev_path = best["path"]
            self.mac = best["address"]
            self.name = best["name"]
        self.connected = best["connected"]
        self.refresh_battery()
        if self.connected and self.session.fd is None and self.link != "dialing":
            self.dial()
        return True

    def retarget_tick(self):
        self.retarget()
        self.refresh_audio()
        self.publish()
        return True

    def device_iface(self):
        return dbus.Interface(self.bus.get_object("org.bluez", self.dev_path), "org.bluez.Device1")

    def on_props(self, interface, changed, invalidated, path=None):
        if path != self.dev_path:
            return
        if interface == "org.bluez.Device1":
            if "Connected" in changed:
                self.connected = bool(changed["Connected"])
                if self.connected:
                    self.dial()
                else:
                    self.session.close("Sluchawki rozlaczone")
            if "Alias" in changed or "Name" in changed:
                self.name = str(changed.get("Alias") or changed.get("Name") or self.name)
            self.refresh_audio()
            self.publish()
        elif interface == "org.bluez.Battery1":
            self.refresh_battery()
            self.publish()

    def on_interfaces(self, path, interfaces):
        if path == self.dev_path and "org.bluez.Battery1" in interfaces:
            self.refresh_battery()
            self.publish()

    def refresh_device(self):
        if not self.dev_path:
            self.retarget()
            return
        try:
            props = dbus.Interface(self.bus.get_object("org.bluez", self.dev_path),
                                   "org.freedesktop.DBus.Properties").GetAll("org.bluez.Device1")
        except dbus.DBusException as exc:
            self.emit("error", where="bluez", message=str(exc.get_dbus_message()))
            self.connected = False
            return
        self.connected = bool(props.get("Connected", False))
        self.name = str(props.get("Alias") or props.get("Name") or self.name)
        self.refresh_battery()

    def refresh_battery(self):
        if not self.dev_path:
            return
        try:
            pct = dbus.Interface(self.bus.get_object("org.bluez", self.dev_path),
                                 "org.freedesktop.DBus.Properties").Get("org.bluez.Battery1",
                                                                        "Percentage")
            self.bluez_battery = int(pct)
        except dbus.DBusException:
            self.bluez_battery = None

    def refresh_audio(self):
        if not self.mac:
            return
        card = "bluez_card." + self.mac.replace(":", "_")
        sink_prefix = "bluez_output." + self.mac.replace(":", "_")
        source_prefix = "bluez_input." + self.mac.replace(":", "_")
        profile, codec = "", ""
        in_card = False
        for line in pactl("list", "cards").splitlines():
            stripped = line.strip()
            if stripped.startswith("Name:"):
                in_card = stripped.split(":", 1)[1].strip() == card
            elif in_card and stripped.startswith("Active Profile:"):
                profile = stripped.split(":", 1)[1].strip()
        # kodek wisi na wezle (sinku), nie na karcie
        in_sink = False
        for line in pactl("list", "sinks").splitlines():
            stripped = line.strip()
            if stripped.startswith("Name:"):
                in_sink = stripped.split(":", 1)[1].strip().startswith(sink_prefix)
            elif in_sink and stripped.startswith("api.bluez5.codec"):
                codec = stripped.split("=", 1)[1].strip().strip('"')
        self.audio = {
            "profile": profile,
            "codec": codec,
            "sink": find_node("sinks", sink_prefix) or "",
            "source": find_node("sources", source_prefix) or "",
            "ldac": ldac_quality_setting(),
        }

    # --- sesja MDR ---
    def dial(self):
        if self.session.fd is not None or not self.connected or not self.dev_path:
            return False
        if self.dial_timer:
            GLib.source_remove(self.dial_timer)
            self.dial_timer = None
        self.set_link("dialing", "Otwieram sesje kontrolna")
        self.session.dial(self.mac)
        return True


def main():
    parser = argparse.ArgumentParser(description="melon.sony helper")
    parser.add_argument("mode", nargs="?", default="serve", choices=["serve", "ctl"])
    parser.add_argument("command", nargs="*")
    parser.add_argument("--mac", default=DEFAULT_MAC)
    parser.add_argument("--adapter", default=ADAPTER)
    args = parser.parse_args()

    if args.mode == "ctl":
        return ctl(args.command)

    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    helper = Helper(args.mac or None, args.adapter)
    helper.start_socket()
    helper.start_bluez()
    helper.refresh_audio()
    helper.publish()

    GLib.io_add_watch(sys.stdin, GLib.IO_IN | GLib.IO_HUP, stdin_ready, helper)
    GLib.timeout_add_seconds(5, lambda: (helper.refresh_audio(), helper.publish(), True)[1])
    GLib.timeout_add_seconds(20, lambda: (helper.refresh_battery(), helper.publish(), True)[1])
    loop = GLib.MainLoop()

    def stop(*_):
        # zamknij sesje po dobroci - zerwane RFCOMM blokuje kolejne proby
        helper.session.close("Koniec pracy")
        loop.quit()

    add_signal = GLibUnix.signal_add if GLibUnix is not None else GLib.unix_signal_add
    for sig in (signal.SIGINT, signal.SIGTERM):
        add_signal(GLib.PRIORITY_DEFAULT, sig, stop)
    loop.run()
    return 0


def stdin_ready(source, condition, helper):
    """Komendy z Panel.qml: linie JSON na stdin (bufor, bo czytanie bywa dzielone)."""
    buf = getattr(stdin_ready, "buf", b"") + os.read(source.fileno(), 4096)
    if not buf:
        return False
    *lines, rest = buf.split(b"\n")
    stdin_ready.buf = rest
    for line in lines:
        line = line.strip()
        if line:
            helper.handle(line.decode("utf-8", "replace"))
    return True


def ctl(argv):
    """Klient CLI: sony-helper.py ctl <komenda> [wartosc]."""
    if not argv:
        argv = ["state"]
    cmd = argv[0]
    payload = {"cmd": cmd}
    if len(argv) > 1:
        value = argv[1]
        if value in ("true", "false"):
            value = value == "true"
        payload["value"] = value
    if cmd == "eq" and len(argv) > 2:
        payload["preset"] = argv[1]
        payload["bands"] = [int(x) for x in argv[2].split(",")]
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(0.7)
            sock.connect(SOCK_PATH)
            sock.sendall((json.dumps(payload) + "\n").encode("utf-8"))
            deadline = time.time() + (0.8 if cmd == "state" else 2.0)
            lines = []
            while time.time() < deadline:
                try:
                    chunk = sock.recv(65536)
                except socket.timeout:
                    break
                if not chunk:
                    break
                lines += [l for l in chunk.decode("utf-8", "replace").splitlines() if l.strip()]
                if cmd == "state" and lines:
                    break
                if any(json.loads(l).get("type") == "error" for l in lines):
                    break
            states = [l for l in lines if json.loads(l).get("type") in ("state", "error")]
            if states:
                print(states[-1])
            return 0
    except OSError as exc:
        print(json.dumps({"error": str(exc)}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
