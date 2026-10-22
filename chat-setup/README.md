# chat-setup

Chat servers for the LAN. Today: an [Ergo](https://ergo.chat) IRC server, so an
IRC client in development (tvmail's chat) can be tested against a server you
own and can watch, instead of a public network. It is also the first step
toward self-hosted chat.

| script | what |
|---|---|
| [scripts/configure-ergo.sh](scripts/configure-ergo.sh) | install and run Ergo, LAN-only, TLS, with NickServ accounts |
| [scripts/ergo-register.py](scripts/ergo-register.py) | create a NickServ account (used by `--register`) |
| [scripts/configure-tvchat.sh](scripts/configure-tvchat.sh) | on a client: point tvmail's chat at that server (CA, `tvchat.conf`, password, a test login) |

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
6. **Opens the firewall**, but only with `--open-firewall`. On a cmpi-router
   box, the script adds the port to `/etc/router-setup/lan0-tcp-ports` and
   runs `setup-router.sh fw`, so the rule survives a firewall reload. That
   reload rebuilds the whole firewall from the list, which would close any
   port opened only at runtime (an `nft add rule`). So if the live firewall
   accepts a TCP port that is in neither `/etc/nftables.conf` nor the list,
   the script refuses, names the ports, and changes nothing: add them to the
   list first. Elsewhere, it prints (or with `--open-firewall` adds) the `nft` rule. Use
   `--firewall-plan` to see what it would do, without root.
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

## The client: tvmail's chat

```sh
./scripts/configure-tvchat.sh --nick yournick --autoconnect
```

Run it as yourself on the machine where tvmail runs (cmlaptop); it needs no
root. `--host` defaults to `cpbee`; run `-h` for every option. It is safe to
re-run. In order, it:

1. **Fetches the CA** with `scp HOST:/opt/ergo/ca.pem`, so ssh's `known_hosts`
   vouches for it (`--ca FILE` uses a copy you already have), and saves it as
   `~/.config/tvmail/ACCOUNT-ca.pem`.
2. **Checks TLS** the way `tvchat-backend` will: Python's `ssl`, with that CA
   and the host name checked against the certificate.
3. **Writes `[account:ACCOUNT]`** into `~/.config/tvmail/tvchat.conf` (or
   `$TVCHAT_CONF`). The section is added, or replaced if it's already there.
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
`--no-check`).
