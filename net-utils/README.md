# net-utils

Small tools for the home LAN (the `cmnet` domain, with the server `cpbee`): who is who, where the passwords are
kept, and the ports and routes of the network. Each tool documents itself: run it with `-h`, or read the
docstring at the top of the file. Python 3 and bash only; they run on Linux, macOS and Cygwin.

| tool | what it is |
|---|---|
| [auth](auth) | password vault on cpbee |
| [identity](identity) | who is who: the logins a person uses on each service (no secrets) |
| [net-login](net-login) | one script for `ssh-mfa`, `sudo-mfa` and `telnet-netrc`: logs in and answers the password / one-time-code prompts (mode = the name it is called by) |
| [get_mfa_code.py](get_mfa_code.py) | the current one-time code (TOTP) for a host, from the vault or a token file; used by `net-login` |
| [netrc-to-tickets](netrc-to-tickets) | move logins from `~/.netrc` into `~/.mu-tickets` |
| [lan-port](lan-port) | open, close and audit the LAN ports of cpbee |
| [traceroute-plus.sh](traceroute-plus.sh) | traceroute that also asks each hop about itself |
| [auth-on-cpbee.sh](auth-on-cpbee.sh) | install or update `auth` and `identity` on cpbee |
| [cpbee-sudo-mfa-setup.sh](cpbee-sudo-mfa-setup.sh) | make `sudo` on cpbee ask for a one-time code, and turn direct root login off |
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

## net-login: ssh, sudo and telnet that answer for you

`make install` puts `net-login` and `get_mfa_code.py` in `$(PREFIX)/bin` with three symlinks to `net-login`. The
script looks at the name it was called by:

| call | what it does |
|---|---|
| `ssh-mfa HOST [ssh options] [command]` | ssh; answers the host's `Token:` / `Verification code:` prompt with a fresh code from `get_mfa_code.py HOST` |
| `sudo-mfa HOST [ssh options] [sudo args]` | `ssh -t HOST sudo ...`; answers sudo's password from `~/.netrc` and its code prompt from `get_mfa_code.py` (no sudo args: `sudo -i`) |
| `telnet-netrc [HOST [PORT]]` | telnet; answers `login:`/`Username:` and `Password:` from `~/.netrc` (the VAX works) |

Any name starting with `ssh-`, `sudo-` or `telnet-` works. A name with another label is a shortcut from
`~/.config/mfa/aliases` (`KEY HOST [USER [READY-REGEX]]`): `ssh-wwl` with the line `wwl whatwelove.org whatwelo Ready!` is
the old `ssh-wwl`; `default-telnet cpvax` is what `telnet-netrc` uses with no host. Without a recognised name:
`net-login ssh|sudo|telnet ...`. More links: `make install MFA_LINKS="ssh-mfa sudo-mfa telnet-netrc ssh-wwl"`.

`get_mfa_code.py HOST [USER]` asks the vault first (`auth totp HOST [USER]`, record kind `totp`), then a token file
(`$MFA_TOKENS`, `~/.config/mfa/tokens.json`; shapes `{"HOST": "SECRET"}`, `{"HOST": {"USER": "SECRET"}}` and the old
`{"USER": "SECRET"}`). It needs no pip package.

Secrets never go on a command line or into the output. A seed for a *second factor* belongs in the master tier of the
vault (needs the vault unlocked), not the service tier. `sudo-mfa` only helps if the host's sudo asks for a code: see
[sudo needs a code on cpbee](#sudo-needs-a-code-on-cpbee). Tests: `bash net-utils/test/test_net_login.sh` (a fake ssh
and telnet; needs `expect`).

## sudo needs a code on cpbee

A stolen ssh key for `chris@cpbee` should not be enough to become root. So on cpbee `sudo` asks for a one-time code
(TOTP, the kind an authenticator app shows) as well as your password, and direct root login over ssh is off. Logging in as
`chris` is unchanged: key only, no code.

**How it works.** The check is in PAM, not in a shell startup file, so it cannot be skipped by running `/usr/bin/sudo`,
a non-interactive shell or another shell (the webhost has no PAM access, which is why it checks in `~/.bashrc`
instead). One line in `/etc/pam.d/sudo`, after `@include common-auth`:

`auth required pam_google_authenticator.so secret=/etc/google-authenticator/${USER} user=root` <!-- allowlist secret -->

The seed is in `/etc/google-authenticator/chris`, owned by root, mode 400, so `chris` cannot read it. A copy is in the
vault's **master** tier as `2fa@cpbee chris` (kind `totp`), which is what lets the laptop make the code; it is not in
the service tier on purpose, so a job key cannot read it and the vault has to be unlocked first.

**Setting it up (once).** From a terminal on the laptop, in a checkout with `net-login` and `get_mfa_code.py`:

```bash
net-utils/cpbee-sudo-mfa-setup.sh               # plan and checks only; changes nothing
APPLY=1 net-utils/cpbee-sudo-mfa-setup.sh       # does it
```

It asks for what is missing (it unlocks the vault, asks for your sudo password and checks it before changing anything,
and offers to save it in `~/.netrc`). Then: installs `libpam-google-authenticator`; makes the seed; backs up
`/etc/pam.d/sudo` to `/etc/pam.d/BAK/sudo.STAMP` (3 newest kept) and adds the line; starts a root-owned 5-minute
timer that puts the backup back **unless** step 3 confirms; runs `sudo-mfa cpbee` to prove password and code both
work; and only then writes `PermitRootLogin no` to `/etc/ssh/sshd_config.d/20-no-root-login.conf` (`sshd -t`, reload,
and a check that `ssh root@cpbee` is refused). Options: `KEEP_ROOT_SSH=1` stops before the root-login step,
`DISABLE_ROOT_SSH=1` does only that step, `PHONE=1` prints an `otpauth://` line to add the seed to a phone app too.

**Using it.**

```bash
sudo-mfa cpbee -i                    # a root shell; password and code are answered for you
sudo-mfa cpbee systemctl status ssh  # one command (a new terminal each time, so a new code each time)
ssh -t cpbee sudo ...                # by hand: type the password, then the code from the vault or an app
auth totp cpbee chris                # the current code (vault unlocked)
```

`sudo-mfa` reads the password from `~/.netrc` (`machine cpbee login chris password ...`) and the code from
`get_mfa_code.py` (vault first). To run several root commands, use one shell or one `sh -c '...'`: a second
`sudo-mfa` within the same 30 seconds has to wait for the next code, because each code works once.

**How long things last (cpbee, 6 hours on purpose, like the webhost's login state).**

| | time | notes |
|---|---|---|
| the code | 30 s, and the previous and next code are accepted too; each works once; 3 tries per 30 s | `WINDOW_SIZE 3`, `DISALLOW_REUSE`, `RATE_LIMIT 3 30` in the seed file |
| the sudo ticket | 360 min | `Defaults:chris timestamp_timeout=360` in `/etc/sudoers.d/90-timeout`; per terminal, renewed by each sudo run; this is the only place a good code is remembered |
| the vault unlock | 6 h from the unlock | `default-cache-ttl` and `max-cache-ttl` 21600 in cpbee's `~/.gnupg/gpg-agent.conf`; after that, `ssh -t cpbee auth unlock`; needed only to make a code, not by a ticket you already hold |

Reloading gpg-agent (`gpgconf --reload gpg-agent`) locks the vault; unlock it again afterwards.

**Limits.** While the vault is unlocked, anything running as `chris` on cpbee can read the seed through `auth`, so the
code is a real second factor only against someone who has the ssh key but not the vault passphrase. For full strength keep
the seed only in a phone app (`PHONE=1`) and remove it from the vault (`auth remove 2fa@cpbee chris`); `sudo-mfa` then
needs the code typed by hand. Keep an out-of-band way in (console, or another admin account with its own code): with root
ssh off and a broken PAM line, sudo is gone.

**Undo.** Each needs a working `sudo-mfa` / `sudo`, so do the PAM one first only if you can still get a code:

```bash
sudo-mfa cpbee cp -p /etc/pam.d/BAK/sudo.STAMP /etc/pam.d/sudo          # no code needed any more
sudo-mfa cpbee rm /etc/ssh/sshd_config.d/20-no-root-login.conf         # root ssh allowed again (then: systemctl reload ssh)
sudo-mfa cpbee rm -r /etc/google-authenticator                         # forget the seed (after the PAM line is gone)
auth remove 2fa@cpbee chris                                            # forget it in the vault
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
bash net-utils/test/test_net_login.sh
```
