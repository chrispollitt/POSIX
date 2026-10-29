# web-ttyd

Run console apps in a browser tab as if they were in a real terminal window: [ttyd](https://github.com/tsl0922/ttyd)
(xterm.js, SIXEL on) behind nginx with basic auth, inside a small desktop-style window (title bar, close / minimise /
maximise, drag, resize).  Written for cpbee.

    https://192.168.10.1:8444/                 the list of apps
    https://192.168.10.1:8444/maze4/           read-only, a new game per tab
    https://192.168.10.1:8444/bidet/           a text prompt that draws pictures (SIXEL), not a shell
    https://192.168.10.1:8444/cpvax/           the OpenVMS VAX: a VT100 login over telnet to 192.168.20.30
    https://192.168.10.1:8444/cpvax-console/   the simh console (127.0.0.1:2323), one client at a time
    https://192.168.10.1:8444/waxweb/          WAX & TAPE: a web page (not a terminal) that drives the VAX's collection program

| file | what |
|---|---|
| `install.sh` | run on cpbee: password file, nginx files, firewall port, systemd user units (`-n` dry run, `-u` remove); safe to re-run |
| `web-ttyd.conf`, `web-ttyd-proxy.conf` | nginx: the https server on the LAN address, auth, one path per app, WebSocket headers |
| `index.html` | the list of apps at `/`; one line per app in its `APPS` array |
| `frame.html` | the window around the terminal, served at `/APP/`; the terminal is ttyd at `/APP/term/` in the iframe |
| `web-ttyd-APP.service` | systemd user units; each runs that app's `ttyd/run-ttyd.sh` |

The launchers live with the apps: `Games/maze4/ttyd/`, `CWPutils/BIDeT/4D/ttyd/` (with `bidet-web.sh`, the prompt)
and `VAX/simh/ttyd/` (with `cpvax-term.sh`, the telnet session).  They need `~/bin/ttyd` (the static release binary)
and, for bidet, a venv with numpy and Pillow (`~/venvs/bidet`).

## waxweb: the odd one out

`waxweb` (`VAX/waxweb`) is an ordinary web server on `127.0.0.1:8088`, so it has no `frame.html` window and no
`/APP/term/`: one `location /waxweb/` in `web-ttyd.conf` proxies it (the trailing `/` on `proxy_pass` strips the
prefix, and the page's URLs are relative, so it works here and at its own root).  Its unit is
`web-ttyd-waxweb.service`.  It logs in to OpenVMS (192.168.20.30:23) as the unprivileged `WAXWEB` account whose
password is in `~/.config/waxweb.env` (mode 600; `install.sh` refuses to go on without it: see
`VAX/waxweb/deploy/waxweb.env.example`).  nginx does the authentication, so waxweb's own `WAXWEB_AUTH` stays unset.
The page can power the VAX on (`VAX_UNIT=vax.service`, the same sudoers line as the cpvax window).

## Adding an app

1. A launcher in the app's repo that runs `ttyd` on its own loopback port (`BASE=/APP/term` makes it live under the path).
2. Here: a `web-ttyd-APP.service`, two `location` blocks in `web-ttyd.conf` (`/APP/` the frame, `/APP/term/` the proxy),
   a title in `frame.html`, a line in `index.html`, and the app in `install.sh`'s `apps` and `launchers`.
3. `./install.sh`.  The one LAN port, 8444, is already open; apps do not need their own.

## Firewall

cpbee's firewall is rebuilt by cmpi-router's `setup-router.sh fw` from `/etc/router-setup/lan0-tcp-ports` and
`lan0-udp-ports`.  A port opened any other way (a runtime `nft add rule`, an edit of `/etc/nftables.conf`) is lost, or
makes `fw` refuse, at the next reload.  Projects open and audit ports with `../net-utils/lan-port` (`add`, `remove`,
`list`, `check`, `plan`); `install.sh` uses it for 8444.

## Notes

- nginx here listens on the LAN address only, so this is reachable from the LAN, not the internet.  Anything wider
  (Tailscale, a port-forward) is a separate decision: bidet's and the VAX's ttyds are *writable* terminals.
- cpvax: the VAX is off until someone powers it on from the window (see `VAX/simh/ondemand/`; the unit has no `[Install]`), so the
  window offers to power it on, shows progress, and connects when it answers.  The console flavour reaches simh itself: Ctrl-E gives the
  `sim>` prompt, where `quit` stops the machine without a VMS shutdown.  `telnet -E` turns off telnet's escape
  character, so neither window offers a `telnet>` prompt or `!` shell escape.
- A `return` in nginx runs before the auth check; `/`, `/APP/` use `rewrite ... break`, which does not skip auth.
- xterm.js answers a program's cell-size query only if the client option `windowOptions` allows it; bidet sizes its
  SIXEL pictures from that answer, so the bidet launcher turns it on.  Without it pictures are drawn too wide and cropped.
- Running a program under `timeout` stops it (SIGTTIN) when it asks the terminal something; use `timeout --foreground`.
- For no browser chrome at all, use F11, or the browser's "install as app" / "create shortcut".
- After `git pull` on cpbee, remove the hand-copied `ttyd/` directories first if they are untracked there.
