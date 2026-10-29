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
./mail-setup.sh --role master --lan auto --pull-every 5 -y   # unattended master
./mail-setup.sh --assume-no          # checks only, changes nothing
```

On a master the wizard also asks two things that `--yes` alone won't answer
for you:

- **Accept mail from LAN clients?** If yes, Postfix listens on all interfaces
  and trusts your LAN (auto-detected, e.g. `192.168.1.0/24`) on port 25 with
  no password, so clients and the sendmail shim can send through it. It's
  off by default because it opens a port; `--lan CIDR|auto|off` answers it
  unattended.
- **Pull every how many minutes?** (default 5, `0` = on demand) Schedules
  `mail-pull`; `--pull-every N`.

Every step is a yes/no offer. Each one is also its own script you can run alone:

| script | does |
|---|---|
| `scripts/configure-sendmail-relay.sh` | Postfix: local delivery + an authenticated TLS smarthost relay; rewrites local senders on the way out. Addresses that LAN clients qualify with their own hostname (`chris@laptop`, i.e. any domain without a dot) are treated as the master's, so they deliver locally and go out as the real mailbox. `--lan CIDR\|auto` lets LAN clients send through it, `--no-lan` (or `--lan off`) goes back to loopback-only; a re-run with neither keeps the current setting, and a re-run without `--relay-file` keeps the current smarthost. `--plus-users` adds per-user `cwp+chris@` senders; the new map is test-built and verified before Postfix is reloaded. Linux only. |
| `scripts/configure-dovecot.sh` | Dovecot IMAP: INBOX = `/var/mail/<user>`, other folders in `~/mail`, with Drafts/Sent/Trash/Junk/Archive auto-created. Writes one drop-in (`conf.d/99-mail-setup.conf`), checks it with `doveconf`, and rolls back if that fails. Handles both Dovecot 2.3 and 2.4 syntax. Linux only. |
| `scripts/configure-sieve.sh` | optional, on the master: ManageSieve (port 4190) + the Sieve plugin, so a client can keep an out-of-office (`vacation`) script there - tvmail's *File > Out of office*. Installs Pigeonhole, writes one drop-in (`conf.d/95-mail-setup-sieve.conf`, checked with `doveconf`, rolled back on failure; 2.3 and 2.4 syntax), points Postfix's `mailbox_command` at `dovecot-lda` (Sieve only runs on mail Dovecot delivers; another `mailbox_command` is kept unless `--force`; pop-pull, getmail and the sendmail shim all deliver via Postfix, so they are covered), and opens 4190 in ufw if active, and when an nftables input chain drops by default says which rule to add (`--open-firewall` adds it for now; clients otherwise just time out). The firewall is `../net-utils/lan-port`'s job: on a cmpi-router box it lists 4190 in `/etc/router-setup/lan0-tcp-ports`, reloads with `setup-router.sh fw` and checks it is open (`configure-dovecot.sh` does the same for 993, and 143 with `--plaintext`). `--listen all` or `local`. Linux only. |
| `scripts/configure-delta.sh` | optional, on the master: mailboxes for Delta Chat (tvchat's `protocol = deltachat`), whose core needs an IMAP *and an authenticated SMTP* login. Creates dedicated users (random passwords, saved to a mode-600 file), makes the mail domain local in Postfix, writes one Dovecot drop-in (`conf.d/96-mail-setup-submission.conf`, mode 644 so `dovecot-lda` can read it; checked with `doveconf`, rolled back on failure; 2.3 and 2.4), adds Postfix `submission` on 587 (STARTTLS + login, relay only for logged-in users, the existing certificate), opens 587 for the LAN through `../net-utils/lan-port` (listed in cmpi-router's `/etc/router-setup/lan0-tcp-ports` and the firewall reloaded; or opens ufw), logs in to IMAP and SMTP as each new user to prove it, and prints the `tvchat.conf` lines. `--domain`, `--users`, `--print`. Linux only. |
| `scripts/configure-mail-pull.sh` | installs `bin/pop-pull` (stdlib-Python POP3S puller) + `~/.config/mailpull.conf`; `--plus-base` routes `cwp+TAG@` mail to local user TAG |
| `scripts/configure-getmail.sh` | installs getmail6 if missing (distro package, else `pip --user`) and writes a `getmailrc` (POP3S, or `--imap`); `--imap --plus-base/--plus-users` fetches the host's per-user tag folders (cPanel) |
| `scripts/configure-webmin.sh` | installs Webmin (official apt repo) if missing and sets its System and Server Status module to check, every 5 min (`--every`), the Postfix mail queue plus Postfix/Dovecot running. You get a local email when a check fails and another when it recovers. `--queue-max` / `--fails` set the queue alarm, `--webhook URL` adds an HTTP call, and `--allow CIDR\|auto\|all` limits who can reach port 10000. The wizard offers it on a master (under `--yes` only when Webmin is already installed). Linux only. |
| `scripts/install-sendmail-shim.sh` | client: installs `bin/sendmail-shim` as `/usr/sbin/sendmail`, forwarding to the master |
| `scripts/configure-mailutils.sh` | installs GNU Mailutils and writes `~/.mail` + `~/.mu-tickets` |

`--help` on any of them prints its options.

### When mail doesn't go out

Every failure notice is delivered locally, to `/var/mail/<you>` on the master,
so it still arrives when the smarthost is what's broken.

- **Postfix** (`configure-sendmail-relay.sh`): a message stuck in the queue
  for 1 hour gets its sender a "delayed" notice (`delay_warning_time`), and
  postmaster (→ root → you) gets a headers-only copy of every bounce, delay
  and undeliverable bounce (`notify_classes`). Your own mail can therefore
  produce two notices: one as sender, one as postmaster.
- **Webmin** (`configure-webmin.sh`, optional): one email when the queue starts
  backing up and one when it has cleared. For the reason a message is stuck, see
  *Servers → Postfix Mail Server → Mail Queue*; the log is at
  *System → System Logs* → `/var/log/mail.log`.

### Pullers and `mail-pull`

Both puller scripts install **`mail-pull`** (in `~/bin`, or `$MAIL_SETUP_BINDIR`),
a two-line wrapper that runs whichever puller you configured last. Timers,
cron and other programs (tvmail's **F3**) just run `mail-pull`, so switching
pullers means re-running the other configure script. `--timer N` on either
script schedules it: a systemd `--user` timer, `mail-pull.timer` (lingering
is enabled so it runs while you're logged out; the old `tvmail-pull.timer` is
removed), or, without systemd (WSL, containers, Cygwin), one crontab line
tagged `# mail-setup: mail-pull` that re-runs replace, never duplicate.

Exit status is pop-pull's: `0` = got mail, `1` = nothing new, `2` = error.
getmail only ever returns 0 or an error.

### Passwords

There's only ever one copy of the mailbox password: Postfix's own
`/etc/postfix/sasl_passwd` (root:your group, mode 640, so the pullers - which
run as you - can read it; nobody else can). `pop-pull` reads it live, and getmail
gets it through `password_command` = `bin/sasl-pass`. Neither `mailpull.conf`
nor `getmailrc` contains it. Client passwords live in `~/.mu-tickets`
(mode 600). None of the files in this project hold credentials.

## Message headers: loud and proud

These tools say what they are and where mail came from, and they never erase
that when they rewrite a message.

| Header | Set by | Meaning |
|---|---|---|
| `X-Mailer: TOOL VERSION` | the originating tool (`tvmail`, else `tvmail-backend`, else `sendmail-shim`) | what composed/submitted it. Only added if the message has no `X-Mailer`/`User-Agent` yet, so the first tool keeps the credit |
| `X-Origin-User`, `X-Origin-Host` | `tvmail-backend`, `sendmail-shim` | the account and machine it was submitted from. Added only if absent, so a re-sent or forwarded message keeps its original origin |
| `X-Relayed-By: TOOL VERSION on HOST (USER)` | `sendmail-shim` (when the caller already named itself) | one hop's trace line |
| `X-Relayed-By: Postfix VERSION on HOST (submitted by USER, uid N)` | Postfix `header_checks` (`configure-sendmail-relay.sh`) | local submissions only, stamped before `smtp_generic_maps` rewrites the sender |
| `X-Pulled-By: pop-pull VERSION on HOST (USER) from LOGIN@SERVER` | `pop-pull` | who fetched it and from which mailbox; the message's own `Received`/`X-Mailer`/`X-Origin-*` are delivered byte for byte |
| `X-Original-From` | `tvmail-backend` when `[smtp] from =` forces the sender | the `From:` it replaced |
| `User-Agent: mail (GNU Mailutils X.Y)` | Mailutils `mail(1)`; `configure-mailutils.sh` pins `set xmailer` in `~/.mailrc` | |

Rules every tool follows: add, never overwrite; when a sender address is
rewritten, keep the original somewhere in the headers. Postfix's own
`Received:` lines are left alone (they already name the host and, for local
mail, the uid). getmail's `Received:` line names getmail the same way.

## Several users, one mailbox (plus-addresses)

A web host often gives you one POP mailbox (say `cwp@u-l.ca`) while the master
has several users (`chris`, `miche`). Plus-addresses let that one public mailbox
serve all of them, each kept apart:

```
 outbound   chris@cpbee --Postfix generic map--> cwp+chris@u-l.ca --smarthost--> world
            miche@cpbee                          cwp+miche@u-l.ca
            root@cpbee                           cwp@u-l.ca            (shared catch-all)

 inbound    cPanel-style host (Dovecot plus-addressing), fetched with getmail --imap:
            world --> cwp+chris@u-l.ca --> folder INBOX.chris --\
            world --> cwp+miche@u-l.ca --> folder INBOX.miche --+-> getmail --> /var/mail/chris
            world --> cwp@u-l.ca ---------> INBOX --------------/               /var/mail/miche
                                                                                 /var/mail/<--local-user>
```

**Where does the host put tagged mail? Check first.** Two kinds of host exist,
and they need different pullers:

- **cPanel / Dovecot** (u-l.ca): mail for `cwp+chris@u-l.ca` is filed in an **IMAP
  folder named `chris`** (shown to IMAP clients as `INBOX.chris`; the host creates
  it on the first such message). It is **not** in the inbox, and POP3 only
  exposes the inbox, so **`pop-pull` never sees it**. Use **`getmail --imap`**,
  which fetches the folders.
- A host that delivers `cwp+chris@...` into the plain inbox keeps the tag in the
  headers (`Delivered-To`, `To`, ...). There `pop-pull --plus-base` (or getmail
  over POP3, by header) works.

Outbound needs the smarthost to accept `cwp+chris@u-l.ca` as sender while you're
logged in as `cwp@u-l.ca` (depends on the host's sender-verification settings).
Test all of it with the live probe (not part of `run-tests.sh`; it sends one real
message to yourself and cleans up after itself):

```bash
tests/live/check-plus-addressing.py --relay-file smtp-relay.txt --tag chris
```

It reports `1.` whether the smarthost accepts the `+tag` sender, `2.` where the
probe landed (`IMAP folder INBOX.chris`, or the inbox via IMAP/POP3), and `3.`
the routing key (the folder name and its prefix, or the header that names the
tag), then recommends `getmail --imap --plus-prefix ...` or `pop-pull`. It
deletes the probe, and the tag folder too if the probe's delivery created it.
If `1` fails, skip `--plus-users` (outbound stays the shared address); if `3`
fails the host strips the tag and inbound routing can't tell users apart.

**Set it up on the master**, as root (or a service account) so one puller can
deliver for everyone:

```bash
# outbound: per-user senders; root/system mail keeps the shared address
sudo scripts/configure-sendmail-relay.sh --relay-file smtp-relay.txt --plus-users chris,miche
# inbound, cPanel-style host: getmail over IMAP, one tag folder per user
sudo scripts/configure-getmail.sh --imap --relay-file smtp-relay.txt \
     --plus-base cwp@u-l.ca --plus-users chris,miche --local-user chris
# inbound, host that delivers tagged mail into the inbox: pop-pull by header
sudo scripts/configure-mail-pull.sh --relay-file smtp-relay.txt --plus-base cwp@u-l.ca --local-user chris
# or all in the wizard (with getmail it implies --imap)
sudo ./mail-setup.sh --role master --puller getmail --plus-base cwp@u-l.ca --plus-users chris,miche
```

- **Outbound** (`configure-sendmail-relay.sh --plus-users`): the generic map gets
  `chris@HOST cwp+chris@u-l.ca` (for the FQDN, short name and `localhost`) next to
  the unchanged `@HOST cwp@u-l.ca` catch-all. Postfix tries `user@host` before
  `@host`, so users get their own address and root, cron and other system mail
  keep the shared one. `--plus-base` overrides which address is tagged (default:
  the smarthost login); `root` can't be listed. `--print` shows the map without
  touching anything.
- **Inbound, getmail --imap** (`--plus-base` + `--plus-users`, the cPanel way):
  one `getmailrc` per folder, each in its own getmaildir
  (`~/.config/getmail/plus-chris/`, ...) so their seen-mail state stays apart:
  `INBOX` -> `--local-user`, `INBOX.chris` -> chris, `INBOX.miche` -> miche.
  The folder name is the routing key, no header parsing, and keep/`--delete`
  and the `sasl-pass` password_command work as for any getmail setup.
  `mail-pull` runs getmail once per rc. INBOX decides the exit status; a tag
  folder only exists after its first tagged message, so a failing folder run is
  reported but not fatal. `--plus-prefix` sets the folder prefix and separator
  (default `INBOX.`; use `INBOX/` or `''` for other servers; the probe prints
  what your host uses). Dovecot folder names are case-sensitive, so only
  lower-case tags (`cwp+chris@`, not `cwp+Chris@`) land in these folders.
  `--plus-headers` additionally routes tagged mail found in INBOX by header
  (the POP3 behaviour below).
- **Inbound, pop-pull** (`--plus-base`; **only for hosts that deliver tagged mail
  into the inbox**, not cPanel-style ones): for each message the first address in
  `Delivered-To`, `X-Original-To`, `To`, `Cc` (in that order) that looks like
  `cwp+TAG@u-l.ca` decides the recipient: `TAG` if the system has that account
  (`getpwnam`, uid >= `plus_min_uid`, default 1000), else `--local-user`. Tags are
  taken from mail headers, so only plain login-name tags are accepted. Delivery is
  `sendmail -oi -- TAG`. Options in `mailpull.conf`: `plus_base`, `plus_sep`
  (default `+`), `plus_min_uid`. A message addressed to several tags goes to the
  first one only.
- **Inbound, getmail over POP3** (no `--imap`; same limitation as pop-pull, it
  only sees the inbox): the `[destination]`
  becomes a getmail **MultiGuesser** (not MultiSorter, which needs a multidrop
  retriever and a trustworthy envelope-recipient header; MultiGuesser works with
  the plain retriever). It checks `Delivered-To`, `Envelope-To`, `To`/`Cc` and
  sends `cwp+chris@` to chris, `cwp+miche@` to miche, everything else to
  `--local-user`. A message addressed to several tags is delivered to each of them.
- **Running it for everyone:** run the puller as root (it reads
  `/etc/postfix/sasl_passwd` directly) or as a service account with `--pwfile` to a
  copy that account can read. Use `--config /etc/mailpull.conf` to keep the
  config out of a home directory; `mail-pull` passes it on. Cron example:
  `*/5 * * * * root /root/bin/mail-pull`. The `--timer` option installs a
  per-user systemd timer, so for root or a service account use cron or write
  your own system unit.
- **Safe to re-run:** the new generic map is test-built with `postmap` in a temp
  dir before anything in `/etc/postfix` changes; after install each user's key is
  looked up and `postfix check` must pass before Postfix is reloaded. If either
  fails, the previous map (and `.db`) is put back. Old maps are kept as
  `generic.bak.<stamp>`.

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
  the in-process servers in `tests/lib/fakeservers.py`. Plus-routing: tag
  matching, header order, unknown/system/hostile tags, `--config`, and the live
  probe `tests/live/check-plus-addressing.py` against fake SMTP/POP3/IMAP servers
  (a cPanel-style one that files `cwp+TAG@` mail in `INBOX.TAG`, and an inbox-only one).
- **shell** (`tests/shell/test_scripts.sh`): runs every configure script for
  real in a throwaway `$HOME` with fake `getmail`/`mail`/MDA, and checks the
  generated files, modes, backups, wrapper switching, Dovecot drop-ins for both
  syntaxes (`configure-dovecot.sh --print`, `configure-sieve.sh --print`), both wizard roles, the per-user
  generic map (`configure-sendmail-relay.sh --print`), the getmail MultiGuesser
  rules (evaluated against sample addresses), the `--imap` per-folder rcs and the
  `mail-pull` wrapper that runs them, and the relay script end to end
  against fake `postmap`/`postfix`/`postconf` in a sandbox `/etc/postfix`
  (install, backup, lookup check, and rollback when `postmap` or
  `postfix check` fails).
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
`MAIL_SETUP_GETMAIL`, `MAIL_SETUP_NO_SYSTEMD=1` (schedule with cron),
`SENDMAIL_DEST`, `MAIL_SETUP_POSTFIX_DIR` and `MAIL_SETUP_ALIASES` (where
`configure-sendmail-relay.sh` writes).

## Layout

```
mail-setup.sh        the wizard
scripts/             one configure script per program
bin/                 pop-pull, sasl-pass, sendmail-shim (installed by scripts/)
lib/                 common.sh (prompts, package managers), pull.sh (mail-pull, timer)
tests/               unit/  shell/  e2e/  lib/  live/ (opt-in, real servers)  run-tests.sh
```
