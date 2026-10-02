# upstream-patches

Local fixes for third-party Omarchy plugins I run. Each `.patch` is a plain
`git diff` against the upstream default branch, so it applies to a fresh clone:

```sh
git clone <upstream-url> /tmp/p
cd /tmp/p && git apply /path/to/upstream-patches/<name>.patch
```

| patch | upstream | what it changes |
|---|---|---|
| `promaa.clock.patch` | `promaaa/sync-calendar-omarchy` | `python3 -B` on the calendar helpers (a `__pycache__` under `plugins/` makes Omarchy reload the plugin), and `setCenterHoverRevealSuppressed` no longer assigns to Omarchy's read-only property — it used to throw a `TypeError` on every sync |
| `io.github.serg3k.omarchy-plugin-wwan.patch` | `serg3k/omarchy-plugin-wwan` | Disconnect must not use `mmcli -m any --disable`: ModemManager implements it as MBIM `RADIO_STATE SET(off)`, which this Quectel RM520N-GL latches in firmware — power-up then fails forever. Uses `--simple-disconnect` + `rfkill block wwan` instead. Also drops a stale error message once the modem is connected |
| `io.github.nick-friedrich.hyprland-dock.patch` | `nick-friedrich/hyprland-dock` | `revealThickness` comes from settings and is clamped (1–80) instead of being hardcoded to 3 |
| `harshith.system-monitor.patch` | `Harshith292002/omarchy-system-monitor` | Dims the monitor label to 75% so it reads as secondary info next to the full-size widgets |

Kept as patches rather than vendored files so `git pull` inside the clone still
works. None of them has been sent upstream.
