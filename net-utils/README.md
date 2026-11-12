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
| [mfa-seed](mfa-seed) | `auth seed` plus a check: makes your one-time-code seed in the vault, shows it as a QR code for a phone app, and verifies the first code |
| [qr-show](qr-show) | draw a QR code in the terminal (ANSI colours, or sixel); pure Python, no packages |
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
auth seed lan LOGIN              # make, store and print (once) your LAN-wide one-time-code seed; `seed HOST LOGIN` for one machine only
auth totp HOST LOGIN --verify CODE   # check a code (the codes before and after count too)
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
| `sudo-mfa --local [sudo args]` | the same for `sudo` on **this** machine, no ssh (also: the name `sudo-local`, `MFA_LOCAL=1`, or this machine's own name or `localhost` as the host). On Windows/Cygwin it elevates instead, see below |
| `sudo-gui COMMAND` (or `sudo-mfa --gui`) | Windows only: run a GUI program elevated through `RunAsAdminClient.exe` |
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

### Doing it for you: password, code, vault

In every mode and on every platform, `net-login` does the password, one-time-code and vault steps itself: the password comes
from `~/.netrc`, the code from the vault (`get_mfa_code.py`). When someone is at the terminal and something is missing, it asks
and fixes it instead of failing:

| missing | what it does |
|---|---|
| the vault is locked | runs `ssh -t cpbee auth unlock` (you type the passphrase), then carries on |
| no code seed for the host | offers `mfa-seed HOST USER` (makes the seed, shows it once for a phone app) |
| no `~/.netrc` entry | asks for the password (not shown); once it has worked it offers to save it in `~/.netrc` (mode 600; the old file goes to `~/BAK`, 3 newest kept). `telnet-netrc` asks for the login too |

`MFA_NO_PROMPT=1` (cron, scripts) turns all asking off: it then fails with a clear message.

### One seed per LAN user

The one-time-code seed belongs to the *person*, not to a machine: `mfa-seed` (no arguments) makes yours, stores it in the vault as
`2fa@lan YOU`, and draws a **QR code** to scan once. That one entry in your authenticator app is good for every machine.
`auth totp HOST YOU` uses a seed for that exact host if there is one, otherwise the LAN one, so `sudo-mfa`, `get_mfa_code.py`
and the cpbee `sudo` check all work from it. A machine that needs its own seed (a site that gave you one, or a reason to
keep it apart) gets it with `mfa-seed HOST`, which then wins for that host. Scan with the phone steady; the terminal font must be
small enough for the whole code to show (`MFA_QR=sixel` for a sixel terminal, `MFA_QR=none` to skip it; the seed is printed under it).

### Windows (Cygwin): elevation instead of sudo

Cygwin has no `sudo`, so on Windows `sudo-mfa --local` (and `sudo-local`, `sudo-gui`) elevate with what Windows offers. It
replaces the two helpers that were in `~/.bashrc` (a `sudo` function and the `sudo2` alias):

1. **Already an administrator** (`net session` succeeds): the command just runs (`bash -c`, like the old `eval`). Nothing is asked.
2. Otherwise **the vault must give a code for you** (the gate; nothing is typed): your LAN seed, or one for this machine. A locked
   vault is unlocked, and a missing seed is offered, as in the table above.
3. Then **terminal**: `ssh localhost COMMAND` (an elevated shell; no command gives you that shell). Any password or code prompt
   it shows is answered like in the other modes. Or **GUI** (`sudo-gui`, `sudo-mfa --gui`): `RunAsAdminClient.exe COMMAND`.

Leading options (`-i`, `-u x`, ...) are dropped, as the old function did. Make your seed once with `mfa-seed` (it
is also offered the first time). `MFA_NO_CODE=1` skips the gate for scripts.

**The gate is a speed bump, not a barrier.** It needs the vault unlocked, which needs your passphrase within the last 6 hours, so
a stranger at an idle session cannot elevate. But any process running as you can call `ssh localhost` or
`RunAsAdminClient.exe` directly and be elevated without a code; it stops mistakes and casual use, not malware. A real barrier
would need the localhost ssh path and the RunAsAdmin server (see `Windows/RunAsAdmin`) to demand the code themselves.

## sudo needs a code on cpbee

A stolen ssh key for `chris@cpbee` should not be enough to become root. So on cpbee `sudo` asks for a one-time code
(TOTP, the kind an authenticator app shows) as well as your password, and direct root login over ssh is off. Logging in as
`chris` is unchanged: key only, no code.

**How it works.** The check is in PAM, not in a shell startup file, so it cannot be skipped by running `/usr/bin/sudo`,
a non-interactive shell or another shell (the webhost has no PAM access, which is why it checks in `~/.bashrc`
instead). One line in `/etc/pam.d/sudo`, after `@include common-auth`:

`auth required pam_google_authenticator.so secret=/etc/google-authenticator/${USER} user=root` <!-- allowlist secret -->

The seed is in `/etc/google-authenticator/chris`, owned by root, mode 400, so `chris` cannot read it. It is the same
seed as your LAN one (`2fa@lan chris`, or `2fa@cpbee chris` if cpbee had its own first), kept in the vault's **master** tier, which is what
lets the laptop make the code; it is not in the service tier on purpose, so a job key cannot read it and the vault has to be unlocked first.

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
sudo-mfa --local -i                  # the same, run ON cpbee (no ssh); also: sudo-mfa cpbee ... or sudo-mfa localhost ... there
sudo-mfa cpbee systemctl status ssh  # one command (a new terminal each time, so a new code each time)
ssh -t cpbee sudo ...                # by hand: type the password, then the code from the vault or an app
auth totp cpbee chris                # the current code (vault unlocked)
```

`sudo-mfa` reads the password from `~/.netrc` (`machine cpbee login chris password ...`) and the code from
`get_mfa_code.py` (vault first). Run **on cpbee** it needs both there: a `machine cpbee ...` line in cpbee's own
`~/.netrc`, and the vault unlocked (`auth totp cpbee chris` works directly on cpbee). The local mode takes the host
name from `hostname -s` and the login from `id -un`, and runs `sudo` itself (`MFA_SUDO` to name another). If you are
already root, there is nothing to answer: `sudo-mfa --local CMD ...` just runs the command (and `sudo-mfa --local -u bob CMD`
or no arguments runs plain `sudo` with them), with no `~/.netrc` line and no code needed. To run several root commands, use one shell or one `sh -c '...'`: a second
`sudo-mfa` within the same 30 seconds has to wait for the next code, because each code works once.

**How long things last (cpbee, 6 hours on purpose, like the webhost's login state).**

| | time | notes |
|---|---|---|
| the code | 30 s, and the previous and next code are accepted too; each works once; 3 tries per 30 s | `WINDOW_SIZE 3`, `DISALLOW_REUSE`, `RATE_LIMIT 3 30` in the seed file |
| the sudo ticket | 360 min | `Defaults:chris timestamp_timeout=360` in `/etc/sudoers.d/90-timeout`; per terminal, renewed by each sudo run; this is the only place a good code is remembered |
| the vault unlock | 6 h from the unlock | `default-cache-ttl` and `max-cache-ttl` 21600 in cpbee's `~/.gnupg/gpg-agent.conf`; after that, `ssh -t cpbee auth unlock`; needed only to make a code, not by a ticket you already hold |

Reloading gpg-agent (`gpgconf --reload gpg-agent`) locks the vault; unlock it again afterwards.

**Limits.** `sudo-mfa --local` on cpbee puts the sudo password in cpbee's `~/.netrc` and gets the code from the vault
there, so while the vault is unlocked anything running as `chris` on cpbee can become root with it: on cpbee the code only
keeps out someone who has the ssh key but not the vault passphrase and cannot read `~/.netrc`. Use it on cpbee for
convenience, not as a second barrier. While the vault is unlocked, anything running as `chris` on cpbee can read the seed through `auth`, so the
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
python3 net-utils/test/test_qr.py
```
