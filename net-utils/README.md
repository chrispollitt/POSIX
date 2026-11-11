# net-utils

Small tools for the home LAN (the `cmnet` domain, with the server `cpbee`): who is who, where the passwords are
kept, and the ports and routes of the network. Each tool documents itself: run it with `-h`, or read the
docstring at the top of the file. Python 3 and bash only; they run on Linux, macOS and Cygwin.

| tool | what it is |
|---|---|
| [auth](auth) | password vault on cpbee |
| [identity](identity) | who is who: the logins a person uses on each service (no secrets) |
| [netrc-to-tickets](netrc-to-tickets) | move logins from `~/.netrc` into `~/.mu-tickets` |
| [lan-port](lan-port) | open, close and audit the LAN ports of cpbee |
| [traceroute-plus.sh](traceroute-plus.sh) | traceroute that also asks each hop about itself |
| [auth-on-cpbee.sh](auth-on-cpbee.sh) | install or update `auth` and `identity` on cpbee |
| [USAGE.md](USAGE.md) | day-to-day use of `identity` and `auth`: unlocking, adding and changing passwords, how the tools get them |

## identity and auth together

`identity` says **who** you are on each service (`chris` on the mail server, `chris-pollitt` on IRC) and holds no
secrets. `auth` holds the **secrets** for those logins. A record in `auth` is `SCHEME@HOST LOGIN -> secret`;
when you leave the login out of `auth get`, it asks `identity` for the login of the current person on that
scheme and host. `auth check` compares the two lists and reports a record with no identity line and the reverse.
`auth render` then writes the vault's passwords into the old files (`~/.mu-tickets`, `~/.netrc`), so the tools
that read those files keep working.

## auth

The LAN's one place for passwords: a gpg-encrypted vault on cpbee, asked from any machine over ssh (nothing is
stored on the client). On cpbee the commands work on the vault directly; elsewhere they run `ssh cpbee auth ...`.
Unlock once at a terminal (`ssh -t cpbee auth unlock`); while it is locked a read exits 4.

```bash
auth get imaps cpbee              # the secret (the login comes from identity, or the only one in the vault)
auth set imaps,smtp@cpbee chris   # store a secret; prompted without echo (--stdin for scripts)
auth list                         # records, no secrets
auth totp HOST                    # the current 6-digit code, from a record stored with --kind totp
auth import netrc                 # take ~/.netrc into the vault (also: tickets, foo; -n plans only)
auth render tickets               # write the passwords into ~/.mu-tickets (also: netrc) between BEGIN/END auth lines
auth check                        # the vault against identity
```

A scheme may be a comma list (`imaps,smtp@cpbee`): one secret for those schemes only, rendered as one ticket line
each. `imap`/`imaps`, `smtp`/`smtps`, `irc`/`ircs` and `http`/`https` match as one; `*` is any scheme; a bare host
gets the LAN domain.

## identity

A plain list, one line per login, with a reason on every line, and no passwords. By default `~/.config/identities`
(`$IDENTITY_FILE`), plus `/etc/identities` read-only.

```bash
identity list [PERSON]
identity login PERSON SCHEME HOST      # that person's login there
identity plan add PERSON SCHEME@HOST LOGIN --why TEXT   # then the same with `add`
identity check                         # compare the list with the apps' configuration files
```

`check` reads `~/.netrc`, `~/.mu-tickets` and the tvmail, tvchat, tvcal and Floyd configurations, and reports
unregistered logins, conflicts, duplicates and admin names that are not registered.

## netrc-to-tickets

`~/.netrc` does not say which protocol a login is for; `~/.mu-tickets` does (`imaps://user:...@host`).  <!-- allowlist secret -->
This turns netrc entries into tickets, asking for the protocol where the port does not decide it, and offers a real
protocol for existing `*://` tickets. It shows the plan first, never prints a password, and backs both files up.

```bash
netrc-to-tickets -n               # show the plan only
netrc-to-tickets                  # do it after you say yes (--move also removes the entries from the netrc)
```

## lan-port

Opens, closes and audits LAN ports on a cmpi-router box (cpbee) through its port lists, so a port is open because
it is listed and survives the next firewall reload.

```bash
lan-port list
lan-port check
lan-port plan 8080 "my service (project)"     # changes nothing; then `add` with the same arguments
lan-port remove 8080
lan-port upnp                                 # ports LAN clients opened by UPnP, and whether cmrouter forwards them too
```

UPnP itself is `sudo ./bin/setup-router.sh upnp` in cmpi-router: miniupnpd on lan0, whose mappings are passed on to the
router upstream of cpbee (cmrouter), so e.g. Vuze's port test can pass through both NATs.

## traceroute-plus.sh

Runs a local traceroute, then logs in over ssh (key-based) to each intermediate hop and runs routing, interface and
traceroute commands there. Options are environment variables (`SKIP_REMOTE_TRACE`, `MAX_HOPS`, `SNIFF`,
`SNMP_COMMUNITY` ...), listed at the top of the script.

```bash
./traceroute-plus.sh TARGET [ssh_username]
```

## auth-on-cpbee.sh

Run from the laptop. Copies `auth` and `identity` to cpbee, installs them in `/usr/local/bin` (sudo, asked there),
sets how long gpg-agent keeps the passphrase, and runs `auth init` (you choose the passphrase) if there is no vault
yet. Safe to run again: an existing vault is left alone, so it also updates the tools.

```bash
./auth-on-cpbee.sh
```

## Installing: make

```bash
sudo make install           # auth, identity, lan-port, netrc-to-tickets, traceroute-plus.sh -> /usr/local/bin
sudo make install-cpbee     # on cpbee: upnp-sync-cmrouter -> /usr/local/sbin, the /router page -> /opt/trafficgraph
                            # (traffic service restarted); the router code itself is ../cmpi-router
make diff                   # repo against the installed copies
make check                  # syntax checks and the lan-port tests
```

`PREFIX`, `DESTDIR` and `TRAFFIC_DIR` can be overridden (`make install DESTDIR=/tmp/stage` is a dry run).

## Tests

The tests live in [test/](test) and use throwaway directories; they touch none of your real files. Run them from the
`POSIX` folder (a Cygwin or Linux shell). `test_auth.py` needs `gpg` and takes about 40 seconds.

```bash
python3 net-utils/test/test_auth.py
python3 net-utils/test/test_identity.py
python3 net-utils/test/test_netrc_to_tickets.py
bash net-utils/test/test_lan_port.sh
```
