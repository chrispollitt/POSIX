# net-utils handoff (2026-11-11)

PR: https://github.com/chrispollitt/POSIX/pull/1 (branch `net-utils-webhost-notes`, docs only).
`python3 net-utils/test/test_auth.py` passes (23 tests). No secrets were printed or added.

## Done

`TO-DO.txt` and the webhost section of `USAGE.md` now record:

- `~/.config/auth/local` makes `auth` use local files; the word `kill-agent` in it makes `auth` stop the gpg-agent after each call.
- The webhost store has no dependency on cpbee.
- Every language's `Foo_Bar` library goes through `Foo_Bar_w.php` to the PHP shim (`shims/Foo_Bar.php`), so no per-language shims are needed. The old `TO-DO.txt` line saying otherwise is corrected.
- The open puzzle below.

## Open puzzle

On the webhost, `bash foo LABEL` returns the correct 8-char login and 32-char secret, but `foo -p LABEL` prints a 6-char field twice.
It may also explain the earlier result where `foo -p` gave 13 characters for all 8 labels.
Next step: read the `-p` handling in `Foo_Bar.bash` and `Foo_Bar_w.php` (originals: `Foo_Bar.php.orig`).

## Not verified

Nothing was run on the webhost, cpbee or the LAN (repo-only session). Two claims come from Chris, not from a check:

- every language's library goes through `Foo_Bar_w.php`;
- the webhost store works with cpbee down.

## Next

1. Review and merge PR 1.
2. Investigate the `foo -p` puzzle (needs the webhost sources or webhost access).
3. Other open items are in `TO-DO.txt` (Phase 1 and Phase 2).

## Notes

- Cloud sessions cannot run `gh pr create` (GraphQL is blocked); use `gh api repos/chrispollitt/POSIX/pulls ...`.
- The cloud clone fetches only `main`, so a hook may report unpushed commits when the remote branch exists; `git push -u origin BRANCH` or `git update-ref refs/remotes/origin/BRANCH SHA` fixes the local view.
