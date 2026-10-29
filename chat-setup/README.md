# chat-setup

Chat servers for the LAN. Today: an [Ergo](https://ergo.chat) IRC server, so an
IRC client in development (tvchat) can be tested against a server you
own and can watch, instead of a public network. It is also the first step
toward self-hosted chat.

| script | what |
|---|---|
| [scripts/configure-ergo.sh](scripts/configure-ergo.sh) | install and run Ergo, LAN-only, TLS, with NickServ accounts |
| [scripts/ergo-register.py](scripts/ergo-register.py) | create a NickServ account (used by `--register`) |
| [scripts/configure-talkd.sh](scripts/configure-talkd.sh) | install talkd as the LAN's talk daemon (service, user, inetd, firewall) |
| [talkd/talkd.py](talkd/talkd.py) | a talk(1) daemon (ntalk on UDP 518) that also rings and relays for tvchat (TCP 518) - in progress |
| [scripts/configure-tvchat.sh](scripts/configure-tvchat.sh) | on a client: point tvchat at that server (CA, `tvchat.conf`, password, a test login) |
| [scripts/configure-floyd.sh](scripts/configure-floyd.sh) | on the master: Floyd, tvchat's bot and tvmail's assistant - the `floyd` user and his mailbox (puller, `tvmail.conf`), his NickServ nick and password, `/etc/tvchat/floyd.conf`, the `tvchat-floyd` systemd unit (runs as `floyd`), and start it; needs tvchat installed (see tvchat's INSTALL.md, "The central Floyd") |
| [scripts/configure-tvchat-delta.sh](scripts/configure-tvchat-delta.sh) | on a client: a Delta Chat account in tvchat on a mailbox made by mail-setup's `configure-delta.sh` (installs the core, `tvchat.conf`, password, a real connect) |

The shared shell helpers come from [`../mail-setup/lib/common.sh`](../mail-setup/lib/common.sh).

## Ergo

```sh
sudo ./scripts/configure-ergo.sh --open-firewall --register yournick
```

Linux with systemd. Run it on the box that should host IRC (cpbee). It is safe
to re-run. Run `-h` for every option. In order, it:

1. **Downloads Ergo** (2.19.1 by default) from its GitHub release and checks
   the SHA-256 twice: against the value pinned in the script, and against the
   release's `checksums.txt`. It unpacks the release to
   `/opt/ergo/ergo-VERSION-ARCH`, with `/opt/ergo/current` pointing at it.
   Debian's `ergo` package is an unrelated chemistry program, which is why
   the script doesn't use apt.
2. **Creates the `ergo` system user.** Accounts and channel registrations live
   in `/var/lib/ergo/ircd.db`.
3. **Sets up TLS.** If the local CA has issued a certificate for this host
   (`/etc/ssl/Simple_Inc/certs/HOST.crt`, `.key` and `HOST-chain.pem`, as on
   cpbee), Ergo uses it. Otherwise the script makes a self-signed certificate
   once. The files go to `/etc/ergo/tls/`: `fullchain.pem` and `privkey.pem`
   for the server, and `ca.pem`, which clients use to verify it. `/etc/ergo/tls`
   is readable only by root and the `ergo` group, because of the key, so
   `ca.pem` is also copied to `/opt/ergo/ca.pem`, which anyone can read.
4. **Writes `/etc/ergo/ircd.yaml`** from the release's own `default.yaml`. Only
   these settings change: the network and server names, the TLS listener
   (bound to the LAN address only, port 6697), the certificate paths, the MOTD
   and the languages directory. Plaintext stays on loopback
   (`127.0.0.1:6667`), as in Ergo's default. If any expected block of
   `default.yaml` is missing or appears twice, the script stops rather than
   write a broken config. It backs up the previous `ircd.yaml` first, and a
   re-run overwrites local edits, so change the options instead.
5. **Installs and starts `ergo.service`**, a sandboxed systemd unit. If Ergo
   does not come up listening, the script puts the previous `ircd.yaml` back
   and shows the journal.
6. **Opens the firewall**, but only with `--open-firewall`, through
   [`net-utils/lan-port`](../net-utils/lan-port), the one script that owns
   the firewall: on a cmpi-router box it adds the port to
   `/etc/router-setup/lan0-tcp-ports`, runs `setup-router.sh fw` and checks the
   port is open, so it survives a firewall reload. That reload rebuilds the
   whole firewall from the lists, which would close any port opened only at
   runtime (an `nft add rule`). So if the live firewall accepts a port that is
   in no list, `lan-port` refuses, names the ports, and changes nothing: add
   them to the list first (`lan-port add PORT "what it is"`). Elsewhere, it
   prints (or with `--open-firewall` runs) the `nft` rule. Use
   `--firewall-plan` to see what it would do, without root; `lan-port check`
   audits the lists against the live firewall afterwards.
7. **Registers NickServ accounts** with `--register NICK`, once per account.
   The script asks for each password, or reads `$CHAT_SETUP_PASS`. Use these
   accounts for SASL.
8. **Prints what a client needs:** the `configure-tvchat.sh` command, and
   how to do it by hand (the `scp` command for `ca.pem` and a `tvchat.conf`
   section).

Defaults: the network is `LAN`, the server is the full hostname (Ergo wants
a dot in a server name, so a bare `cpbee` becomes `cpbee.lan`), and the
listen address is `lan0`'s IPv4 (else the first global one). Override them
with `--network`, `--server-name`, `--listen` and `--port`.

`--remove` stops and removes the service and `/opt/ergo`, but keeps
`/etc/ergo` and `/var/lib/ergo`, so a re-install keeps the accounts.

## talkd (in progress)

[`talkd/talkd.py`](talkd/talkd.py) is a stdlib-Python talk daemon for the
LAN master - **one** for the LAN; laptops run none. It is tvchat's way into
talk(1) (TUIs `HANDOFF.md`, milestone 6):

- **For talk:** ntalk on UDP 518 - invitations kept, looked up and deleted,
  and a user logged in on the host rung on their terminal with the classic
  `Message from Talk_Daemon@...` lines. An unknown caller is named by
  address, not refused. A drop-in for the stock talkd.
- **For tvchat:** TCP 518. tvchat says `HELLO USER`; from then on a call
  for that user rings tvchat (`RING`), not a terminal. tvchat can `CALL`
  another tvchat user, someone logged in on the host, or `user@host` (that
  host's own talkd is asked, the standard way).
- **The relay:** talkd carries every conversation a tvchat user is in - it
  connects to the real talk itself, or takes the real talk's connection on
  a relay port of its own - and splices the bytes, so laptops take no
  inbound connections. The protocol is in the module's docstring.

Checked against inetutils' `talk` (Cygwin) both ways: a real talk calling a
tvchat user, and a tvchat user calling someone whose real talk answers.
(That `talk` took ~10 s before its first request on a laptop whose host
name resolved to a link-local address - its own lookup, not the daemon.)

```sh
sudo ./scripts/configure-talkd.sh --firewall-plan    # what it would open (and whether it may)
sudo ./scripts/configure-talkd.sh --open-firewall
```

It installs `/opt/talkd/talkd.py`, a `talkd` system user, and
`talkd.service` (group tty to ring terminals, CAP_NET_BIND_SERVICE for
port 518, nothing else); comments a talk/ntalk line out of
`/etc/inetd.conf`; answers only loopback and lan0's subnet (`--allow`).
`--open-firewall` calls [`net-utils/lan-port`](../net-utils/lan-port), which lists UDP 518
in `/etc/router-setup/lan0-udp-ports` (cmpi-router's `setup-router.sh` reads it
since 2026-10-22) and TCP 518 + the relay ports 5181-5188 in `lan0-tcp-ports`,
reloads once with `setup-router.sh fw`, and checks they are open - and, as
`configure-ergo.sh` does, refuses (changing nothing) if that reload would close
a port open only by a live rule, TCP or UDP: the October mail-port outage.
(Since 2026-10-22 `setup-router.sh` itself refuses such a reload too, from
any of its modes - `FW_FORCE=1` overrides; its `svc-*` ftp/telnet rules are
exempt.)

Next: tvchat's side (`protocol = talk`).

## The client: tvchat

```sh
./scripts/configure-tvchat.sh --nick yournick --autoconnect
```

Run it as yourself on the machine where tvchat runs (cmlaptop); it needs no
root. `--host` defaults to `cpbee`; run `-h` for every option. It is safe to
re-run. In order, it:

1. **Fetches the CA** with `scp HOST:/opt/ergo/ca.pem`, so ssh's `known_hosts`
   vouches for it (`--ca FILE` uses a copy you already have), and saves it as
   `~/.config/tvchat/ACCOUNT-ca.pem`.
2. **Checks TLS** the way `tvchat-backend` will: Python's `ssl`, with that CA
   and the host name checked against the certificate.
3. **Writes `[account:ACCOUNT]`** into `~/.config/tvchat/tvchat.conf` (or
   `$TVCHAT_CONF`). If that file doesn't exist yet but the old
   `~/.config/tvmail/tvchat.conf` does (chat was part of tvmail until
   tvchat 0.1.0), the old one is copied there first; tvchat reads the new
   one from then on. The section is added, or replaced if it's already there.
   Every other section and comment stays, and the file is backed up first; an
   unchanged file is left alone. `cafile` gets the full path, since
   `tvchat-backend` doesn't expand `~`. Comments go on lines of their own, since
   a comment after a value becomes part of it. `--autoconnect` adds the
   account to `[chat] autoconnect`.
4. **Stores the SASL password.** If `$TVCHAT_PASS_ACCOUNT` is set or
   `~/.netrc` already has `machine HOST`, nothing changes. Otherwise the
   script asks (or reads `$CHAT_SETUP_PASS`) and adds the password to
   `~/.netrc`, mode 600. If `~/.netrc` has that machine for another login,
   the script stops before it changes anything.
5. **Logs in once with SASL PLAIN**, under a throwaway nick that quits before
   registering, to show that the account and password work.

`--no-check` skips the TLS check and the login (offline); `--no-sasl`
connects without an account.

### A second person to talk to

Register a second nick (`--register tester2`), then connect a second client:
`irssi` on the server box (plaintext on loopback is fine there), or a second
`[account:...]` section with `tvchat-backend irc-tail`.

## Tests

```sh
./tests/test_chat_setup.sh
```

These tests need no root, no network and no Linux. They cover the
`ircd.yaml` made from a cut-down `default.yaml` (set
`ERGO_DEFAULT_YAML=/path/to/the/real/default.yaml` to also convert the real
one), the unit, the download pin, the firewall plan, option checks, and
`ergo-register.py` against a fake NickServ, and `configure-tvchat.sh`'s
edits of a `tvchat.conf` and `~/.netrc` in a sandboxed `HOME` (with
`--no-check`). `configure-floyd.sh`'s `floyd.conf` and systemd unit are checked through
its `--print-config` / `--print-unit`.
