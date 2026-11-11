# Using identity and auth, day to day

`identity` says **who** you are on each service (logins, no secrets). `auth` holds the **secrets** for those
logins in an encrypted vault on cpbee. This page is the everyday view; `auth --help` and `identity --help` have
every option, and [README.md](README.md) has the overview.

## The picture in five lines

- The vault is one gpg file on cpbee (`~/.local/share/auth/vault.gpg`), encrypted to the key `auth-vault`.
- Writing to it needs no passphrase. **Reading it does**, and that is what "unlock" means.
- On any other machine, `auth` runs `ssh cpbee auth ...`; nothing is stored on the client.
- The old files (`~/.mu-tickets`, `~/.netrc`) are **generated** from the vault by `auth render`.
- The tools (tvmail, tvchat, tvcal, tvcontacts, ftp ...) still read those files. They do not talk to the vault.

## How often do I unlock the vault?

About **once per working day, and only when you touch the vault itself.**

```bash
ssh -t cpbee auth unlock      # asks for the vault passphrase once; gpg-agent on cpbee keeps it
```

- The agent keeps the passphrase **8 hours** from the last use, and **24 hours at most** in any case
  (`default-cache-ttl 28800`, `max-cache-ttl 86400`, set by `auth-on-cpbee.sh`).
- You need it for `auth get | set | remove | list | totp | render | import | check`. Each exits **4** and says
  "vault is locked" if the cache has run out. Unlock and run it again.
- You do **not** need it for ordinary use. Mail, calendar, contacts and ftp read the already-rendered files,
  so they keep working while the vault is locked.
- Reboot of cpbee, or `gpgconf --kill gpg-agent` there, locks it again.
- Want it tighter (cpbee shared with others)? Lower the two numbers in `~/.gnupg/gpg-agent.conf` on cpbee.

Lost the passphrase or the key? The vault cannot be read. The secret key is backed up off-site (done
2026-11-04); keep that backup and the passphrase safe.

## Add, update, delete

Always: `SCHEME@HOST LOGIN`. A bare host gets the LAN domain (`cpbee` is `cpbee.cmnet`). Unlock first.

```bash
auth list                              # what is in the vault (no secrets)
auth list imaps@cpbee                  # just one service

auth set https@cpbee:5232 michelle     # ADD: prompts twice, no echo
auth set https@cpbee:5232 michelle     # UPDATE: same command; it says "changed" instead of "added"
printf '%s\n' "$PW" | auth set imap,imaps,smtp,smtps@cpbee chris --stdin   # from a script (never on a command line)
auth set 2fa@whatwelove.org whatwelo --kind totp    # a TOTP seed (base32 text, as the site shows it)

auth remove https@cpbee:5232 michelle # DELETE one record
auth remove imaps@cpbee chris          # on a multi-scheme record: drops that scheme (imap and imaps count as one), keeps the others
```

Notes:

- **One record can serve several schemes**: `imap,imaps,smtp,smtps@cpbee`. Use a comma list when the same login
  and secret apply to all of them (tvmail asks `imap://`, others ask `imaps://`; Mailutils matches exactly).
- `--note TEXT` keeps a reminder with the record. `--kind` is `password` (default) or `totp`.
- Matching ignores the port; `https@cpbee:5232` keeps `:5232` only for rendering.
- Changing a secret keeps where the record came from: a record imported from the old `~/.foo` manager stays
  out of every rendered file, and one imported from a netrc stays in the netrc.

### After a change: render

The tools do not see a new password until the files are regenerated:

```bash
auth render tickets -n        # dry run: shows the plan, no secrets
auth render tickets           # writes ~/.mu-tickets (mail, calendar, contacts, IRC); backs up the old one first
auth render netrc             # writes ~/.netrc (ftp/telnet and the like)
```

Run it on **each machine whose files should change** (laptop, and anyone else's account on cpbee). Each run
keeps a `.bak-DATE` copy of the previous file; those backups are plaintext, so delete them when the result is
right. Only the block between `# BEGIN auth` / `# END auth` (and older lines for the same login) is touched;
the rest of the file stays yours.

## How do systems get a password?

There is **no SSO, no export, no shim, no agent socket** today. Three ways exist, in order of how much they
are used:

| Way | How it works | Used by |
|---|---|---|
| **1. Rendered files** (the default) | `auth render` writes `~/.mu-tickets` / `~/.netrc` (mode 600) from the vault. The tool reads its usual file. | tvmail, tvchat, tvcal, tvcontacts, Mailutils, ftp/telnet to the VAX, Delta Chat's smtp login |
| **2. Ask the vault** | A script runs `auth get SCHEME HOST [LOGIN]` (prints the secret on stdout, exit 1 if none, 4 if locked) or `auth totp HOST` (prints the 6-digit code). Works from any machine over ssh. | `ssh-wwl` (TOTP for whatwelove.org; the old `get2fa_code.py` is its fallback) |
| **3. Type it** | `auth get` in your own terminal when you need a password once. | you |

Things to know:

- Way 1 means the secret **is a plaintext file on that machine** (mode 600), exactly as before. The vault
  protects the master copy and gives one place to change a password; it does not encrypt the rendered files.
- Way 2 needs the vault unlocked at that moment. Scripts should handle exit 4 (`ssh -t cpbee auth unlock`).
- Other Unix users and services (Floyd, Michelle) and jobs do not read your master vault. They get **service
  records** (next section), which need no unlock.
- Planned, not built: a git credential helper, `auth` called directly by the tv apps with the files as a
  fallback, `auth ca` to hand out the CA file (all in `TO-DO.txt`).

## Jobs: cron and Scheduled Tasks (the service tier)

A job cannot type the vault passphrase, so it uses a second tier:

- **Service tier:** records stored with `--service` live in `service.gpg`, encrypted to a key with **no
  passphrase**. Put in it only what a job truly needs. These secrets are protected by file permissions on cpbee
  and by the ssh restrictions below, not by a passphrase.
- **One ssh key per job or machine**, tied to a forced command (`auth serve NAME`) that can only `get` or `totp`,
  only from the service tier, and only the records on that client's allow list. A stolen job key cannot list,
  change, or read anything else.

```bash
# once, on cpbee's side (from any machine, you at the keyboard):
auth set --service imaps@cpbee chris --note "nightly mail check"     # a service record
# on the machine that runs the job:
ssh-keygen -t ed25519 -N '' -f ~/.ssh/auth_service                   # a key with no passphrase, for this job only
auth enroll nightly --allow imaps@cpbee/chris --stdin < ~/.ssh/auth_service.pub

# in the job (cron line, Scheduled Task, script): no unlock, no prompt
pw=$(auth get imaps cpbee chris)            # uses ~/.ssh/auth_service automatically when nothing is typing at it

auth clients                                # who is enrolled and what each may read
auth unenroll nightly                       # revoke
```

On a client, `auth get` and `auth totp` use `~/.ssh/auth_service` when stdin is not a terminal (or when
`AUTH_SERVICE_KEY` names a key file), and fall back to your normal ssh key if that fails. On cpbee itself a job
reads the service tier directly. `auth list` marks service records `[service]`.

First time only: `auth init-service` on cpbee (the install script `auth-on-cpbee.sh` does it).

### A machine with its own store (the webhost)

A host that cannot reach cpbee (whatwelove.org is outside the LAN) keeps its own service tier. Install `auth` there
(it is `~/local/usr/bin/auth`), create the file `~/.config/auth/local` (its presence makes `auth` use the local files
instead of ssh to cpbee), and run `auth init-service`. Jobs there call `~/local/usr/bin/auth get SCHEME HOST LOGIN`
directly; no ssh and no unlock are involved. Fill it with `auth set --service ...`, or take the old Foo_Bar file
with `auth import foo ~/.foo/bar --service` (its key is `~/.ssh-OLD/id_rsa`, the default). This store is separate
from cpbee's: a password changed in one is not changed in the other. <!-- allowlist secret -->

## Changing a password, start to finish

1. Change it on the service (mail account, Radicale, router ...).
2. `ssh -t cpbee auth unlock` (if it is locked).
3. `auth set SCHEME@HOST LOGIN` and type the new one.
4. `auth render tickets` (and `netrc`) on every machine that uses it.
5. Try the tool. Delete the `.bak-*` files with `rm -i ~/.mu-tickets.bak-*`.

## identity: who is who

The list is `~/.config/identities` (one line per login, with a reason). No secrets.

```bash
identity list                          # the whole list (or: identity list chris)
identity login chris imaps cpbee       # which login does chris use there?   -> chris
identity person irc cpbee Floyd        # whose login is this?                -> floyd
identity admins                        # logins flagged admin (Floyd's admins)

identity plan add michelle https@cpbee michelle --why "..."   # what add would do; changes nothing
identity add  chris https@cpbee.cmnet chris --why "calendar"  # add a line (the list is backed up first)
identity remove chris https@cpbee.cmnet chris
identity check                         # list vs the configs (tickets, netrc, tvchat/tvmail/tvcal confs)
```

When you leave the login out of `auth get`, `auth` asks `identity` which login the current person uses on
that service. Add the identity line **before** (or along with) the vault record for a new login.

## Keeping the two in step

```bash
auth check          # LAN records with no identity line, and identity lines with no vault secret
auth check --all    # also outside hosts (gmail, github ...)
identity check      # logins in use that the list does not know; Floyd's admins; duplicates
```

Expect `identity check` to show 0 findings. `auth check` lists identity lines that still have no vault secret
(Delta Chat, Floyd's IRC logins, `cpollitt` on the VAX): these are Phase 2 items in `TO-DO.txt`.

## When something goes wrong

| Symptom | Fix |
|---|---|
| `vault is locked or unreadable` / exit 4 | `ssh -t cpbee auth unlock` |
| `ssh cpbee auth ...` fails | cpbee down, or no ssh key on this machine |
| Mail says "no password for cpbee" | the tickets file lacks that host spelling: `auth render tickets` (it writes both `cpbee` and `cpbee.cmnet`) |
| `bad toplevel token` in a netrc | a `#` comment in `~/.netrc`; Mailutils reads it as a word. `render netrc` writes none; delete the line |
| `auth set` says "the two did not match" | typed it differently twice; run again |
| Wrong password rendered | `auth list SCHEME@HOST` to see the records; fix with `auth set`, then render | <!-- allowlist secret -->
| Two records answer one lookup | the exact scheme wins over `*`; remove the one you do not want |

## Cheat sheet

```bash
ssh -t cpbee auth unlock                      # once a day, when you will touch the vault
auth list | auth get imaps cpbee | auth totp whatwelove.org
auth set SCHEME@HOST LOGIN                    # add or change
auth remove SCHEME@HOST LOGIN
auth render tickets ; auth render netrc       # then the tools see it
auth check ; identity check
```
