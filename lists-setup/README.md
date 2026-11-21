# lists-setup

Mailing lists for the LAN, LISTSERV style: the lists are **mlmmj** lists, people join and leave by mailing
commands to `listserv@HOST` (`SUBSCRIBE`, `SIGNOFF`, `SET ... DIGEST`, `LIST`), and list mail arrives in each
member's own IMAP folder `Lists/NAME`. Read and answer it with
[tvmail](https://github.com/chrispollitt/TUIs/tree/main/tvmail)'s Lists service, or any mail client. This is the server
half of tvmail's
[SERVICES-DESIGN.md](https://github.com/chrispollitt/TUIs/blob/main/tvmail/SERVICES-DESIGN.md); it builds on
[mail-setup](../mail-setup/) (Postfix, Dovecot, and its Sieve step).

| file | what |
|---|---|
| [scripts/configure-lists.sh](scripts/configure-lists.sh) | on the mail master: install mlmmj, `listserv` and `listctl`, wire Postfix (two pipe services, two tables) and Dovecot (one global Sieve rule), make the first lists |
| [bin/listserv](bin/listserv) | the command handler Postfix feeds `listserv@HOST` to: reads the commands, does them, answers by mail |
| [bin/listctl](bin/listctl) | make, remove and configure lists, manage members, rewrite the Postfix tables |
| [bin/listlib.py](bin/listlib.py) | what the two share: configuration, the list directory layout, members, the Postfix tables |
| [bin/list-import](bin/list-import) | turn old mailing-list material (an ARPANET-style archive, an rmail file of digests, one long document) into list mail and deliver it to members' folders |
| [scripts/configure-tvmail-lists.sh](scripts/configure-tvmail-lists.sh) | on a client: point tvmail at it (`[lists]` in `tvmail.conf`) |
| [tests/](tests/) | `test_lists_setup.sh` (runs the other too), `test_lists.py` |

The shared shell helpers come from [`../mail-setup/lib/common.sh`](../mail-setup/lib/common.sh).

## The server

```sh
sudo ./scripts/configure-lists.sh --list "lan-talk:Talk on the LAN" --list "announce:News for everyone" \
                                  --owner chris@cpbee.cmnet
```

Linux, on the box that runs Postfix and Dovecot (cpbee), after `configure-sieve.sh` (mail delivered through
`dovecot-lda`); the script stops and names the script to run first if something is missing. Safe to re-run; `-h` has
every option. No port is opened: list mail uses the SMTP the box already accepts from the LAN. It:

1. installs the `mlmmj` package and its user;
2. installs `listserv` and `listctl` in `/usr/local/bin` and writes `/etc/lists-setup/lists.conf` (the domain, the spool
   `/var/spool/mlmmj`, where mlmmj's tools are);
3. Postfix, as mlmmj's own README.postfix has it: the tables `/var/spool/mlmmj/virtual` and `transport` (kept by
   `listctl`) are added to `virtual_alias_maps` and `transport_maps` (and `virtual` to `local_recipient_maps`: the SMTP
   server checks a recipient in a local domain against that before any alias, and would refuse a list address as "User
   unknown" otherwise), `recipient_delimiter` must be `+`, and master.cf gets
   two pipe services run as the `mlmmj` user: `mlmmj` (a list address reaches `mlmmj-receive`) and `listserv`
   (`listserv@HOST` reaches the command handler). `main.cf` and `master.cf` are backed up first (`BAK/` beside them, the
   3 newest kept) and put back if `postfix check` fails;
4. Dovecot: one **global Sieve script**, `/etc/dovecot/sieve-before.d/90-lists.sieve`, that files mail with
   `List-Id: <NAME.DOMAIN>` into `Lists/NAME` (created on the first mail) and **stops**, so a member's own filters, a
   vacation reply above all, never answer list mail. It is declared in `/etc/dovecot/conf.d/96-lists-setup-sieve.conf`
   (Dovecot 2.3 and 2.4 syntax), compiled with `sievec`, and the old state comes back if `doveconf` rejects it;
5. a cron entry for `mlmmj-maintd` (digests, bounces, retries) every 10 minutes;
6. makes the lists named with `--list`.

`--print-config lists.conf|postfix-main|postfix-master|sieve-script|dovecot-dropin|cron` shows each piece without
touching anything.

### Lists

```sh
sudo listctl create NAME --description "what it is" [--owner ADDR]... [--moderated] [--closed-sub] [--open-post]
sudo listctl list | show NAME | members NAME
sudo listctl add NAME ADDR... [--digest]       # people can join by themselves with SUBSCRIBE
sudo listctl set NAME description TEXT | owner ADDR... | moderated on|off | closed-sub on|off | open-post on|off
sudo listctl remove NAME --yes                 # moved to /var/backups/lists-setup, not deleted
sudo listctl sync                              # rewrite the Postfix tables and reload
```

A new list is `NAME@DOMAIN`, with the subject prefix `[NAME]`, a `List-Id: <NAME.DOMAIN>` header (what the Sieve rule
keys on), posting by members only (`--open-post`: anyone), a digest every day, and mlmmj's own mail commands switched
off (`closedlist`): members come and go through `listserv@`. `closedlistsub` (`--closed-sub`) makes `SUBSCRIBE` refuse
with "ask the owner"; mlmmj's `submod` is refused the same way, since `listserv` does not run the approval flow.

### Filling a list with old material

`list-import` makes what mlmmj would have delivered out of old list archives and puts it in a member's folder:

```sh
list-import --list sf-lovers --domain cpbee.cmnet --dry-run  "zip::listservs/SF-LOVERS_Digest_Vol_01.txt"   # count only
sudo list-import --list sf-lovers --state /var/lib/lists-setup/sf-lovers-chris.ids \
     "zip::listservs/SF-LOVERS_Digest_Vol_01.txt" -- /usr/lib/dovecot/dovecot-lda -d chris
```

A source is a file or `ZIPFILE::MEMBER`. Three shapes are read: an **ARPANET-style archive** (messages one after
another, each with its own `Date:` / `From:` / `Subject:`; SF-Lovers of 1979), an **rmail (Babyl) file** where each
record is one message (the digest issues of SF-Lovers volumes 13 and 25), and **one long document** cut into one
message per numbered section (`--format sections --date 1994-09-10 --title Cyphernomicon`). Each message gets the
shape of a list mail: `List-Id: <NAME.DOMAIN>`, `To: NAME@DOMAIN`, the `[NAME]` subject prefix, a clean `From` (old
`USER at HOST` forms become `USER@HOST.invalid`), the date read from forms like `15 SEP 1979 2216-PDT`, a
`Message-ID` (kept when real, made up from the content otherwise), `X-Archive-Source`, and UTF-8 text. Delivery runs a
command once per message (`-- CMD ARG...`): the delivery agent hands the mail to Dovecot, whose Sieve rule files it
into `Lists/NAME` like any list mail. `--state` records the Message-IDs delivered, so a re-run skips them; `--out
FILE.mbox` writes an mbox instead.

## The commands

Mail to `listserv@HOST`, one command per line of the text (or, with none, the Subject). Whoever sends the mail is the
one who is subscribed, signed off or switched: **nobody can act for another address** (an address on the LAN can be
forged, so this is a courtesy, not security; the LAN is the trust boundary, as for the rest of the mail setup).

| command | |
|---|---|
| `LIST` | the lists there are |
| `INFO list` | what it is, its owner, how many members, who may post |
| `SUBSCRIBE list [First Last]` | join (the name is accepted and not kept) |
| `SIGNOFF list` | leave (`UNSUBSCRIBE`, `LEAVE`) |
| `SET list DIGEST` / `NODIGEST` / `NOMAIL` / `MAIL` | one digest mail per interval, every message, post only, normal |
| `REVIEW list` | the members, for members and the owner |
| `HELP` | this |

**The answer** is a mail to the sender, `In-Reply-To` the command mail's `Message-ID`, with `Auto-Submitted:
auto-replied` and a null envelope sender, so it can never start a loop. The first line of its text is the verdict, `OK
...` or `ERROR ...`; for `LIST` every following line is `name  description`. With several commands in one mail the
first line says how they went overall and each command follows as `> command`. This is the contract tvmail's Lists
service is built to; `listserv` never answers robots, bounces, other lists or itself (`Auto-Submitted`, `Precedence:
bulk`, `List-Id`, `X-Loop`, system sender addresses are ignored).

## The clients

On each machine that runs tvmail:

```sh
./scripts/configure-tvmail-lists.sh --address listserv@cpbee.cmnet --realname "Chris P"
```

It writes `[lists]` and `lists` in `[services] order` into `~/.config/tvmail/tvmail.conf`, keeping every comment and
section. tvmail reads list mail over IMAP with the Mail service's login, so it needs `[service] mode = remote`; the
script says so when the mode is local.

## Tests

```sh
./tests/test_lists_setup.sh     # 55 checks: the files configure-lists.sh would write, its option checks, the whole
                                # install in a sandbox against fake postconf / postfix / doveconf / sievec (re-runs,
                                # backups, both rollbacks, each missing prerequisite), the client script - and the
                                # two Python suites below
python3 tests/test_lists.py     # 28 checks: listlib, listserv (every command, the loop guards), listctl, end to end
python3 tests/test_list_import.py   # 23 checks: list-import - old date and address forms, the splitters, delivery
```

The handler and tvmail's Lists service were also run against each other once (tvmail's real backend verbs, the real
`listserv`, a fake IMAP server): the list of lists, subscribe with the folder made, digest, sign-off and both error
answers came out as the contract says.

Nothing here installs mlmmj or touches a real Postfix or Dovecot. **Not yet run on the box**, written from the
documentation of mlmmj 1.5, Postfix and Dovecot 2.4 and tested against fakes; the first run on cpbee is the real test:

- `postconf -M` taking the whole master.cf line, and Postfix expanding `--sender=${sender}` in the pipe's argv;
- the `localhost.mlmmj` dummy domain route (virtual table, then transport) and `+extension` addresses reaching
  `mlmmj-receive` (Postfix rewrites a list address to the dummy domain, as mlmmj's README.postfix describes);
- mlmmj's own tools: `mlmmj-sub -f -q -a ADDR` / `-d` switching a member between the normal and the digest list, and the
  files `mlmmj-make-ml` would add (`listctl` writes the layout itself because `mlmmj-make-ml` is interactive);
- whether a digest mail carries the `List-Id` header (digests are made by mlmmj; if not, they land in the INBOX, not in
  `Lists/NAME`);
- the Sieve rule and the folder separator on the real store (cpbee: mbox under `~/mail`, `/`).
