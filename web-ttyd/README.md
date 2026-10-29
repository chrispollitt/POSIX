# web-ttyd

Run console apps in a browser tab as if they were in a real terminal window: [ttyd](https://github.com/tsl0922/ttyd)
(xterm.js, SIXEL on) behind nginx with basic auth, inside a small desktop-style window (title bar, close / minimise /
maximise, drag, resize).  Written for cpbee; the apps are `maze4` and `bidet` (BIDeT 4D).

    https://192.168.10.1:8444/maze4/     read-only, a new game per tab
    https://192.168.10.1:8444/bidet/     a text prompt that draws pictures (SIXEL), not a shell

| file | what |
|---|---|
| `install.sh` | run on cpbee: password file, nginx files, two systemd user units (`-n` dry run, `-u` remove) |
| `web-ttyd.conf`, `web-ttyd-proxy.conf` | nginx: the https server on the LAN address, auth, one path per app, WebSocket headers |
| `frame.html` | the window around the terminal, served by nginx at `/APP/`; the terminal is ttyd at `/APP/term/` |
| `web-ttyd-maze4.service`, `web-ttyd-bidet.service` | systemd user units that run each app's `ttyd/run-ttyd.sh` |

The launchers live with the apps: `Games/maze4/ttyd/run-ttyd.sh` and `CWPutils/BIDeT/4D/ttyd/run-ttyd.sh`
(with `bidet-web.sh`, the prompt).  They need `~/bin/ttyd` (the static release binary) and, for bidet, a venv with
numpy and Pillow (`~/venvs/bidet`).

## Notes

- nginx here listens on the LAN address only, so this is reachable from the LAN, not the internet.  Anything wider
  (Tailscale, a port-forward) is a separate decision: bidet's ttyd is a *writable* terminal.
- A `return` in nginx runs before the auth check, so `/` redirects (the page it leads to asks for the password) and
  `/APP/` uses `rewrite ... break`, which does not skip auth.
- xterm.js answers a program's cell-size query only if the client option `windowOptions` allows it; bidet sizes its
  SIXEL pictures from that answer, so the bidet launcher turns it on.  Without it pictures are drawn too wide and cropped.
- Running a program under `timeout` stops it (SIGTTIN) when it asks the terminal something; use `timeout --foreground`.
- For no browser chrome at all, use F11, or the browser's "install as app" / "create shortcut".
- After `git pull` on cpbee, remove the hand-copied `ttyd/` directories first if they are untracked there.
