# net-utils handoff (2026-11-11)

`python3 net-utils/test/test_auth.py` passes (25 tests, Cygwin Python 3.12). No secrets were printed or added.
Everything below is on `main` in POSIX, WebApps (`user_bash/Foo_Bar.bash`) and Strata (`bin/check_email.pl`).

## State

- **Webhost deployed and verified (2026-11-11, scripts in `~/src/Claude/TO_BE_RUN/DONE/`):** `~/local/usr/bin/auth`, `~/user_php/Foo_Bar.php` (the shim) and `~/user_bash/Foo_Bar.bash` (with `-p`) are the new versions. A test through the real chain (bash `foo`/`bar` -> `Foo_Bar_w.php` -> shim -> `auth`) passed: the real `cp1.uhcloud.com:cpanel` entry (`foo -p` = the 32-char secret alone), and a made-up label for `bar` add, replace (awkward characters), `bar -delete`, and no record left behind.
- **`foo` and `bar` both work in the shim.** `bar($login, $secret, $label)` runs `auth bar LABEL LOGIN --service --stdin`; the secret goes on stdin. `bar("-delete", x, $label)` removes it.
- **The `foo -p` puzzle is solved:** the webhost's `Foo_Bar.bash` was a 2016 copy with no `-p` handling, so `-p` was taken as the label and `failed<TAB>failed` (13 characters) came out. Not the data, the import or the shim.
- **A second, separate bug was found on the webhost:** its Python is 3.7.17, whose `argparse` takes `auth bar --service --stdin LABEL LOGIN` for unknown options (reproduced on Python 3.11.2; Cygwin's 3.12 hides it). `auth` now uses `parse_known_intermixed_args`, and the shim puts the options last. This probably affected other commands with options before the arguments (e.g. `auth set --service ...`) on the webhost too.
- **Backups on the webhost:** `auth.bak-20261110` (before the service tier) and `auth.bak-20261111` (before this deploy), `Foo_Bar.php.bak-20261111` and `Foo_Bar.php.orig` (2015 original), `Foo_Bar.bash.orig`. To undo: copy a backup over the installed file. `~/tmp-deploy` holds the downloaded files and can be deleted.
- **Other:** `Strata/bin/check_email.pl` asks `auth` first (`imaps gmail.com --with-login`), `foo` as the fallback; run end to end by Chris. `Strata/bin/node/check_email.js` is an unported Perl copy, left alone. `auth` with `--with-login` is installed on the laptop and on cpbee.

## Not verified

- Every language's library (perl, python, js) goes through `Foo_Bar_w.php`: Chris's claim, not checked.
- The webhost store works with cpbee down: Chris's claim, not checked.
- The real webhost callers (cpanel.php and the cron-run scripts) were not re-run after this deploy beyond the bash `foo`/`bar` test.
- `ssh-wwl` reports "login failed" and exits whenever remote output contains the words "permission denied" (a false match in its expect pattern); it hid the output of one diagnostic run.

## Next (see `TO-DO.txt`)

1. Re-run one real webhost caller (e.g. cpanel.php) and the cron-run scripts that use `foo`, to confirm nothing regressed.
2. Back up the webhost's `auth-service` key (no passphrase) and the cpbee one.
3. Move the remaining `Foo_Bar` callers (Strata: `fob-log-query.pl/.js`, `program_enterphone.sh`, `unit-query.pl`; WebApps: see TO-DO Phase 2) to `auth get`.
4. A real Scheduled Task on cmlaptop and a crontab line on cpbee.
5. Phase 3 shims (tv suite `password_cmd`, `auth render --tmp`), then Phase 4 and 5.

## Notes

- Cloud sessions cannot run `gh pr create` (GraphQL is blocked); use `gh api repos/chrispollitt/POSIX/pulls ...`.
- The cloud clone fetches only `main`, so a hook may report unpushed commits when the remote branch exists; `git push -u origin BRANCH` or `git update-ref refs/remotes/origin/BRANCH SHA` fixes the local view.
- Webhost scripts are run from the laptop with `ssh-wwl` (see the `TO_BE_RUN` scripts); GitHub raw URLs can be cached for a few minutes after a push.
