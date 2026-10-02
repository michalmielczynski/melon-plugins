# melon.lights

Control IKEA __DIRIGERA__ smart lights from the Omarchy top bar. Pick a room from the pill selector and control the whole room at once: on/off, brightness, color temperature and color hue. Everything runs **locally** against the Dirigera LAN API — no cloud, no IKEA account.

## Install

```
omarchy plugin add https://github.com/<you>/omarchy-lights.git --enable
```

Requires a running IKEA DIRIGERA hub reachable on your LAN, and Python 3 (uses only the standard library — no pip installs).

## Setup (one-time)

The plugin reads the Dirigera JWT token from `~/.config/ikea-dirigera-token.txt`.

Generate it (press the **Action** button on the hub when asked):

```sh
python3 ~/.config/omarchy/plugins/melon.lights/dirigera.py generate-token
```

The token is written to `~/.config/ikea-dirigera-token.txt` with mode `600`.

## Configuration

| Setting | Default | Env override |
|---|---|---|
| Hub IP | `192.168.0.38` | `DIRIGERA_IP` |
| Hub API port | `8443` | `DIRIGERA_PORT` |
| Token file | `~/.config/ikea-dirigera-token.txt` | `DIRIGERA_TOKEN` |

## Security

- **Plugin runs unsandboxed** with your user permissions (Omarchy runtime). Review what it does.
- The Dirigera hub uses a **self-signed certificate**; the helper connects with TLS verification disabled (`verify=False`), which is required for the hub but means the connection is not TLS-authenticated. It is a plain LAN API.
- The JWT token grants **full control of your hub** (lights, scenes, outlets). Keep it in `~/.config/ikea-dirigera-token.txt` (mode `600`) or via `DIRIGERA_TOKEN`. It is never shipped or committed; it is read at runtime.
- No data leaves your machine.

## License

MIT
