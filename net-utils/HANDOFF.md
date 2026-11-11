# net-utils handoff (2026-11-11)

PR 1 (branch `net-utils-webhost-notes`, docs only) is merged.
`python3 net-utils/test/test_auth.py` passes (25 tests, after the later update below). No secrets were printed or added.

## Done

`TO-DO.txt` and the webhost section of `USAGE.md` now record:

- `~/.config/auth/local` makes `auth` use local files; the word `kill-agent` in it makes `auth` stop the gpg-agent after each call.
- The webhost store has no dependency on cpbee.
- Every language's `Foo_Bar` library goes through `Foo_Bar_w.php` to the PHP shim (`shims/Foo_Bar.php`), so no per-language shims are needed. The old `TO-DO.txt` line saying otherwise is corrected.
- The open puzzle below.

## Update (later 2026-11-11, local session)

- PR 1 was merged by fast-forward; `main` also has `auth bar LABEL LOGIN --stdin` / `--delete` and `bar()` in the PHP shim, so `foo` and `bar` both work through the shim (25 tests pass under Cygwin). Not yet run on the webhost.
- The `foo -p` puzzle is explained (from the sources, not yet checked on the webhost): the webhost's `Foo_Bar.bash` is the old WebApps copy with no `-p` handling, so `-p` was taken as the label and `failed<TAB>failed` (13 characters) came out. The fix is the `-p` version of `user_bash/Foo_Bar.bash`, on WebApps branch `foo-bar-p-option`.

## Open puzzle (resolved above, webhost still to do)

On the webhost, `bash foo LABEL` returns the correct 8-char login and 32-char secret, but `foo -p LABEL` printed `failed` twice (13 characters).
To do on the webhost: `grep -c skip ~/user_bash/Foo_Bar.bash` (0 = old copy), keep the old file as `Foo_Bar.bash.orig`, copy the new one over, check that `foo -p LABEL` prints the secret alone.

## Not verified

Nothing was run on the webhost, cpbee or the LAN (repo-only session). Two claims come from Chris, not from a check:

- every language's library goes through `Foo_Bar_w.php`;
- the webhost store works with cpbee down.

## Next

1. On the webhost: deploy `auth`, `shims/Foo_Bar.php` and the `-p` `Foo_Bar.bash`; try `bar auser apass ahost:aserv`, `foo ahost:aserv`, `bar -delete x ahost:aserv`, `foo -p LABEL`.
2. Merge the WebApps branch `foo-bar-p-option`.
3. Other open items are in `TO-DO.txt` (Phase 1 and Phase 2).

## Notes

- Cloud sessions cannot run `gh pr create` (GraphQL is blocked); use `gh api repos/chrispollitt/POSIX/pulls ...`.
- The cloud clone fetches only `main`, so a hook may report unpushed commits when the remote branch exists; `git push -u origin BRANCH` or `git update-ref refs/remotes/origin/BRANCH SHA` fixes the local view.
