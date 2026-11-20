# news-setup

A Usenet server for the LAN: **INN2**, the real thing, with no peers and no feeds, so nothing
outside can reach it. What is on it is an archive of old articles you import, and what the LAN
posts to `lan.*`. Read it with [tvmail](https://github.com/chrispollitt/TUIs/tree/main/tvmail)'s
Usenet service, or any newsreader. This is the server half of tvmail's
[SERVICES-DESIGN.md](https://github.com/chrispollitt/TUIs/blob/main/tvmail/SERVICES-DESIGN.md).

| file | what |
|---|---|
| [scripts/configure-inn.sh](scripts/configure-inn.sh) | on the master: install INN2, configure it for the LAN, create the local groups, open the port (only with `--open-firewall`) |
| [scripts/create-groups.sh](scripts/create-groups.sh) | make the groups of a list, read-only |
| [bin/news-import](bin/news-import) | feed old articles (mbox, Maildir, a spool tree, tar, zip, rnews batches) to the server with IHAVE, made fit for it |
| [bin/fetch-archive](bin/fetch-archive) | list and download the files of an Internet Archive item, checked against its md5s |
| [groups.d/classic.list](groups.d/classic.list) | a starting set of well-known groups, `net.*` before the renaming included |
| [scripts/configure-tvmail-news.sh](scripts/configure-tvmail-news.sh) | on a client: point tvmail at the server (`[news]` in `tvmail.conf`), after checking it answers |
| [tests/](tests/) | `test_news_setup.sh` (runs the others too), `test_news_import.py`, `test_fetch_archive.py`, a fake innd |

The shared shell helpers come from [`../mail-setup/lib/common.sh`](../mail-setup/lib/common.sh).

## The server

```sh
sudo ./scripts/configure-inn.sh --firewall-plan          # what opening the port would do; changes nothing
sudo ./scripts/configure-inn.sh --open-firewall          # install, configure, start, open TCP 119 for the LAN
```

Linux with systemd and apt (Debian, Ubuntu, Raspberry Pi OS). Run it on the box that should host
news (cpbee). Safe to re-run; `-h` has every option. It:

1. installs the `inn2` package;
2. sets what it needs in `/etc/news`, and nothing else:
   - **inn.conf**: only `organization`, `pathhost`, `artcutoff: 0` (an article of 1987 is not "too
     old"), `maxartsize` and `verifycancels: false` change; the rest of the package's file stays;
   - **readers.conf**: the machine itself and the `--allow` networks (default: lan0's subnet) may read
     everything and post to `lan.*` only; any other machine is refused;
   - **incoming.conf**: no peers, except `127.0.0.1`, so `news-import` can feed the archive;
   - **expire.ctl**: nothing ever expires.

   A file that changes is backed up first, in `BAK/` beside it (the 3 newest are kept);
3. restarts INN if a file changed, and waits for port 119;
4. creates `lan.misc`, `lan.talk` and `lan.test` (`--local-groups`) with posting allowed;
5. the firewall, through [`net-utils/lan-port`](../net-utils/lan-port) like the other servers: on a
   cmpi-router box port 119 is listed in `/etc/router-setup/lan0-tcp-ports` and the firewall reloaded
   once. **This is an exposure change** (it lets the LAN talk to the server), so it is off unless you
   say `--open-firewall`; `--firewall-plan` shows it.

`--print-config readers.conf|incoming.conf|expire.ctl` and `--print-config inn.conf FILE` print what it
would write, and `--config-only` writes just the files (for a sandbox, or INN installed some other way).

## The archive

Which groups are *key* is yours to say; [groups.d/classic.list](groups.d/classic.list) is a start.
Archive groups are made read-only (flag `n`): the server takes an article for them from a feed and
from nobody posting, which is how `news-import` adds them, and nobody on the LAN can post into 1987.

```sh
sudo ./scripts/create-groups.sh groups.d/classic.list               # the groups, read-only
bin/fetch-archive --item usenethistorical --list --match 'comp\.lang'   # what is there, with sizes
bin/fetch-archive --item usenethistorical --match 'comp\.lang\.c' --to ~/usenet
bin/news-import --groups groups.d/classic.list --dry-run ~/usenet/*.zip # read and repair, send nothing
bin/news-import --groups groups.d/classic.list ~/usenet/*.zip           # feed it to the server
```

`news-import` reads an mbox (also `.gz`, `.bz2`, or inside a `.zip`), a Maildir or a directory tree of
article files, a `.tar`/`.tar.gz` of them, or an rnews batch (`-` for standard input). It makes each article
fit for a server that has never heard of it: a missing `Message-ID` is made up (a hash of the article, so a
re-run makes the same one), a missing `Path:` added, a `Date:` the server would not take (two-digit years,
zone names, nonsense) rewritten with the old one kept as `X-Original-Date`, and `Newsgroups:` cut down to the
groups you keep. **`Control:`, `Supersedes:`, `Xref:` and `Approved:` are removed** (kept as `X-Original-...`),
so an old `newgroup`, `rmgroup` or `cancel` cannot do anything to your server. It resumes (`--state`), and
the server's "I have that" is a duplicate, not an error. Its summary says how many were read, repaired,
accepted, already there, rejected (and why) and skipped.

**Where the articles come from** is not settled here, and is yours to check:

- The Internet Archive has several Usenet collections (an item called `usenethistorical` is the one
  known to hold mbox files per group, as zip files); `fetch-archive --list` shows what an item really holds
  today, with sizes, and downloading asks first. The names, sizes and licences were **not** verified when
  this was written; look before you download.
- The best-known early archive, the UTZOO NetNews archive of 1981-1991, **was taken down from the Internet
  Archive in 2020** after legal demands; third-party mirrors exist. Treat anything that was removed with
  care.
- The articles are other people's writing. A LAN-only server for yourself is the intent.

## The clients

On each machine that runs tvmail:

```sh
./scripts/configure-tvmail-news.sh --host cpbee --subscribed lan.misc,comp.lang.c
```

It asks the server first (so a closed firewall is found here), then writes `[news]` and `news` in
`[services] order` into `~/.config/tvmail/tvmail.conf`, keeping every comment and section.

## Tests

```sh
./tests/test_news_setup.sh      # 57 checks: the config files, the option checks, the firewall plan,
                                # create-groups with a fake ctlinnd, the client script with a fake
                                # server - and both Python suites below
python3 tests/test_news_import.py     # the importer, against a fake innd
python3 tests/test_fetch_archive.py   # the downloader, against a local imitation of archive.org
```

Nothing here installs INN or talks to a real news server. **Not yet run on the box**: the `inn2`
package, the unit name, what `readers.conf` / `incoming.conf` do in the version Debian ships, and the
`IHAVE` import into a real `innd` are written from INN's documentation and tested against fakes; the
first run on cpbee is the real test (the script says what it saw if `innd` does not come up).
