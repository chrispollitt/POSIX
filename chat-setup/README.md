# chat-setup

Chat servers for the LAN. Today: an [Ergo](https://ergo.chat) IRC server, so an
IRC client in development (tvmail's chat) can be tested against a server you
own and can watch, instead of a public network. It is also the first step
toward self-hosted chat.

| script | what |
|---|---|
| [scripts/configure-ergo.sh](scripts/configure-ergo.sh) | install and run Ergo, LAN-only, TLS, with NickServ accounts |
| [scripts/ergo-register.py](scripts/ergo-register.py) | create a NickServ account (used by `--register`) |

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
   for the server, and `ca.pem`, which clients use to verify it.
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
   runs `setup-router.sh fw`, so the rule survives a firewall reload.
   Elsewhere, it prints (or with `--open-firewall` adds) the `nft` rule. Use
   `--firewall-plan` to see what it would do, without root.
7. **Registers NickServ accounts** with `--register NICK`, once per account.
   The script asks for each password, or reads `$CHAT_SETUP_PASS`. Use these
   accounts for SASL.
8. **Prints what a client needs:** the `scp` command for `ca.pem` and a
   `tvchat.conf` section.

Defaults: the network is `LAN`, the server is the short hostname, and the
listen address is `lan0`'s IPv4 (else the first global one). Override them
with `--network`, `--server-name`, `--listen` and `--port`.

`--remove` stops and removes the service and `/opt/ergo`, but keeps
`/etc/ergo` and `/var/lib/ergo`, so a re-install keeps the accounts.

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
`ergo-register.py` against a fake NickServ.
