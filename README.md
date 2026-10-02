# melon-plugins

Plugins I run in [Omarchy](https://github.com/basecamp/omarchy)'s Quickshell
bar, plus the patches I keep on the third-party plugins I also use.

Everything here is MIT (see [LICENSE](LICENSE)) unless a plugin says otherwise
in its `manifest.json`. The per-plugin notes are mostly written in Polish —
that is the language they were built in; the code is commented in English.

## What's inside

| plugin | kind | what it does | needs |
|---|---|---|---|
| `melon.bar` | bar | My bar: islands, workspaces with window icons, tray, plugins pill, clock, status, power. Drop-in replacement for `omarchy.bar` (`bar.id` in `shell.json`) | — |
| `melon.eye` | bar-widget, overlay | An eye in the bar that tracks the cursor and blinks (double blinks sometimes, dilates as the cursor comes close). Click it and a ring follows the cursor while click rings bloom where you click — built for screencasts | `python3`, `python-evdev`, Hyprland IPC (`hyprctl`) |
| `melon.dock` | overlay | Auto-hiding dock at a screen edge | — |
| `melon.menu` | menu, bar-widget | Command menu (Omarchy's menu plugin, reworked) | — |
| `melon.audio` | bar-widget | Volume slider, output picker, per-app mixer (Omarchy's audio plugin, reworked) | — |
| `melon.media-keep-awake` | service | Keeps the screensaver and lock away while MPRIS media is playing | — |
| `melon.lights` | bar-widget | IKEA DIRIGERA rooms: on/off, brightness, colour temperature | `python3`, a DIRIGERA hub on the LAN, a hub token |
| `melon.rekuperacja` | bar-widget | Ventilation unit (Thessla Green AirPack Home) from the bar: on/off, fan speeds, bypass, temperatures | `python3`, the Modbus-to-HTTP bridge on a Raspberry Pi |
| `melon.sony` | bar-widget | Sony WF-1000XM5: battery of both buds and the case, ANC/Ambient, EQ, DSEE, Speak-to-Chat, LDAC | `python3`, BlueZ over D-Bus |

## Installing

Omarchy keeps plugins in `~/.config/omarchy/plugins/<id>/`. Symlink or copy the
directory you want in there, then enable it:

```sh
ln -s "$PWD/melon.eye" ~/.config/omarchy/plugins/melon.eye
omarchy plugin enable melon.eye
```

Bar widgets also have to be in the bar's layout — `omarchy bar` edits that, or
edit `bar.layout` in `~/.config/omarchy/shell.json` directly. A few of these
patched Omarchy's own widgets, so check `melon.bar`'s `Bar.qml` against the
stock one before you switch your `bar.id` to it.

## Tokens and addresses stay out of the repo

Nothing secret is committed here. The helpers read their credentials and
addresses from the environment or from files outside the repo, for example:

| value | default | where it comes from |
|---|---|---|
| DIRIGERA hub | `192.168.0.38` | `DIRIGERA_IP` |
| DIRIGERA token | – | `$DIRIGERA_TOKEN`, else `~/.config/ikea-dirigera-token.txt` |
| rekuperacja bridge | `http://192.168.0.90:8770` | `RK_BRIDGE` |

Those IPs are just the defaults from my own LAN — override them for yours.

## upstream-patches

`upstream-patches/*.patch` are the local changes I run on top of third-party
plugins that live in the same `plugins/` directory but are their own clones
(`omadock`, `omamail`, `omarchy-display`, `promaa.clock`,
`harshith.system-monitor`, `io.github.nick-friedrich.hyprland-dock`,
`io.github.serg3k.omarchy-plugin-wwan`). Apply one inside a fresh clone:

```sh
git clone <upstream-url> && cd <clone> && git apply /path/to/<name>.patch
```

They are small fixes — a missing guard, a bar colour read from the theme, an
extra field on a label. Kept as patches so the clones stay updatable.

## Credit

- `melon.bar`, `melon.menu` and `melon.audio` are modified copies of Omarchy's
  own bar, menu and audio plugins — MIT, © Basecamp, DHH and the Omarchy
  contributors.
- Everything under `upstream-patches/` belongs to its upstream author; the
  patches are offered back under that project's license.
