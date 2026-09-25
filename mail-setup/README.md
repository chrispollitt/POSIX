# mail-setup

Set up standard Unix mail on a small home network: **GNU Mailutils**,
**Postfix**, **Dovecot**, and a puller (**pop-pull** or **getmail**), or a
sendmail shim for thin clients. It's a wizard plus one script per program,
all re-runnable. Split out of [tvmail](https://github.com/chrispollitt/TUIs/tree/main/tvmail),
which imports it into `third_party/`, but it doesn't depend on tvmail.

## The layout it builds

```
              ISP / web host (POP3S, SMTP submission)
                  ^ pull                    ^ relay (SASL + TLS)
                  |                         |
   +--------------+-------------------------+-------------+
   | MASTER (Linux / Pi)                                   |
   |   pop-pull | getmail --> sendmail --> /var/mail/$USER |
   |   Postfix: local delivery + smarthost relay          |
   |   Dovecot: IMAP, INBOX = /var/mail/$USER, ~/mail/*    |
   +------------------+-----------------------------------+
                      | IMAP (993 / 143) + SMTP (25)
        +-------------+-------------+
        | CLIENTS (laptop, WSL, Cygwin, VMs)
        |   mail(1) via ~/.mail + ~/.mu-tickets
        |   /usr/sbin/sendmail = sendmail-shim -> master:25
        +---------------------------+
```

## Quick start

```bash
./mail-setup.sh                      # asks: master or client, then each step
./mail-setup.sh --role client        # skip the question
./mail-setup.sh --role master --puller getmail
./mail-setup.sh --assume-no          # checks only, changes nothing
```

Every step is a yes/no offer. Each one is also its own script you can run alone:

| script | does |
|---|---|
| `scripts/configure-sendmail-relay.sh` | Postfix: local delivery + an authenticated TLS smarthost relay; rewrites local senders on the way out. Linux only. |
| `scripts/configure-dovecot.sh` | Dovecot IMAP: INBOX = `/var/mail/<user>`, other folders in `~/mail`, with Drafts/Sent/Trash/Junk/Archive auto-created. Writes one drop-in (`conf.d/99-mail-setup.conf`), checks it with `doveconf`, and rolls back if that fails. Handles both Dovecot 2.3 and 2.4 syntax. Linux only. |
| `scripts/configure-mail-pull.sh` | installs `bin/pop-pull` (stdlib-Python POP3S puller) + `~/.config/mailpull.conf` |
| `scripts/configure-getmail.sh` | installs getmail6 if missing (distro package, else `pip --user`) and writes a `getmailrc` (POP3S, or `--imap`) |
| `scripts/install-sendmail-shim.sh` | client: installs `bin/sendmail-shim` as `/usr/sbin/sendmail`, forwarding to the master |
| `scripts/configure-mailutils.sh` | installs GNU Mailutils (a source build on Cygwin) and writes `~/.mail` + `~/.mu-tickets` |

`--help` on any of them prints its options.

### Pullers and `mail-pull`

Both puller scripts install **`mail-pull`** (in `~/bin`, else `~/.local/bin`),
a two-line wrapper that runs whichever puller you configured last. Timers,
cron and other programs (tvmail's **F3**) just run `mail-pull`, so switching
pullers means re-running the other configure script. `--timer N` on either
script installs a systemd `--user` timer, `mail-pull.timer`. That replaces the
old `tvmail-pull.timer`, which gets removed.

Exit status is pop-pull's: `0` = got mail, `1` = nothing new, `2` = error.
getmail only ever returns 0 or an error.

### Passwords

There's only ever one copy of the mailbox password: Postfix's own
`/etc/postfix/sasl_passwd` (mode 600). `pop-pull` reads it live, and getmail
gets it through `password_command` = `bin/sasl-pass`. Neither `mailpull.conf`
nor `getmailrc` contains it. Client passwords live in `~/.mu-tickets`
(mode 600). None of the files in this project hold credentials.

## Platforms

| | master | client |
|---|---|---|
| Debian / Ubuntu / Raspberry Pi OS | yes | yes |
| Fedora / Arch | should work (untested) | yes |
| macOS, BSDs | no | yes |
| Cygwin | no (no Postfix/Dovecot) | yes; Mailutils is built from source |

## Tests

```bash
./tests/run-tests.sh            # everything
./tests/run-tests.sh unit       # bin/* against fake POP3/SMTP servers
./tests/run-tests.sh shell      # every script + the wizard in a sandbox $HOME
./tests/run-tests.sh e2e        # the real chain, plus a live master check
```

- **unit** (`tests/unit/`): `pop-pull` (keep/delete/dry-run, dot-stuffing,
  bad login, failed delivery, password file parsing), `sasl-pass`, and
  `sendmail-shim` (`-t`, Bcc stripping, `-f`, exit codes 66/71), all against
  the in-process servers in `tests/lib/fakeservers.py`.
- **shell** (`tests/shell/test_scripts.sh`): runs every configure script for
  real in a throwaway `$HOME` with fake `getmail`/`mail`/MDA, and checks the
  generated files, modes, backups, wrapper switching, Dovecot drop-ins for both
  syntaxes (`configure-dovecot.sh --print`), and both wizard roles.
- **e2e** (`tests/e2e/`):
  - `test_pull_e2e.py`: `configure-*.sh` → `mail-pull` → pop-pull / real
    getmail → POP3S with a verified self-signed cert (openssl) → MDA,
    including the rejected-untrusted-cert path. The getmail cases skip when
    getmail isn't installed.
  - `e2e_master.sh`: on a configured Linux master, sends a message through
    Postfix, finds it in `/var/mail`, through Dovecot (`doveadm`) and with
    `mail(1)`, checks the special-use folders, then expunges it. Needs root
    or passwordless sudo; otherwise it skips (exit 77). As root, set
    `MAIL_SETUP_E2E_USER=<user>`. Opt-in extras: `MAIL_SETUP_E2E_PULL=1`
    (dry-run pull from your ISP) and `MAIL_SETUP_E2E_SEND_TO=addr` (relay a
    real message out).

The tests only change a temp dir. Environment hooks they use (also handy for
dry runs): `MAIL_SETUP_SUDO=` (never escalate), `MAIL_SETUP_MDA`,
`MAIL_SETUP_GETMAIL`, `SENDMAIL_DEST`.

## Layout

```
mail-setup.sh        the wizard
scripts/             one configure script per program
bin/                 pop-pull, sasl-pass, sendmail-shim (installed by scripts/)
lib/                 common.sh (prompts, package managers), pull.sh (mail-pull, timer)
tests/               unit/  shell/  e2e/  lib/  run-tests.sh
```
