# net-utils handoff (2026-11-11)

`python3 net-utils/test/test_auth.py` passes (25 tests, Cygwin Python 3.12). No secrets were printed or added.
Everything below is on `main` in POSIX, WebApps (`user_bash/Foo_Bar.bash`) and Strata (`bin/check_email.pl`).

## State

- **Webhost deployed and verified (2026-11-11, scripts in `~/src/Claude/TO_BE_RUN/DONE/`):** `~/local/usr/bin/auth`, `~/user_php/Foo_Bar.php` (the shim) and `~/user_bash/Foo_Bar.bash` (with `-p`) are the new versions. A test through the real chain (bash `foo`/`bar` -> `Foo_Bar_w.php` -> shim -> `auth`) passed: the real `cp1.uhcloud.com:cpanel` entry (`foo -p` = the 32-char secret alone), and a made-up label for `bar` add, replace (awkward characters), `bar -delete`, and no record left behind.
- **`foo` and `bar` both work in the shim.** `bar($login, $secret, $label)` runs `auth bar LABEL LOGIN --service --stdin`; the secret goes on stdin. `bar("-delete", x, $label)` removes it.
- **The `foo -p` puzzle is solved:** the webhost's `Foo_Bar.bash` was a 2016 copy with no `-p` handling, so `-p` was taken as the label and `failed<TAB>failed` (13 characters) came out. Not the data, the import or the shim.
- **A second, separate bug was found on the webhost:** its Python is 3.7.17, whose `argparse` takes `auth bar --service --stdin LABEL LOGIN` for unknown options (reproduced on Python 3.11.2; Cygwin's 3.12 hides it). `auth` now uses `parse_known_intermixed_args`, and the shim puts the options last. This probably affected other commands with options before the arguments (e.g. `auth set --service ...`) on the webhost too.
- **Backups on the webhost:** `auth.bak-20261110` (before the service tier) and `auth.bak-20261111` (before this deploy), `Foo_Bar.php.bak-20261111` and `Foo_Bar.php.orig` (2015 original), `Foo_Bar.bash.orig`. To undo: copy a backup over the installed file. `~/tmp-deploy` holds the downloaded files and can be deleted.
- **Shim redeployed (2026-11-11, `webhost-redeploy-shim-failed-and-env.sh`, all tests passed):** `foo()` returns `["failed","failed"]` for a missing label (the original contract; `.pt/fb.php` tests `$user == 'failed'`), and `auth` is run with HOME and PATH set (`/usr/local/bin:/usr/bin:/bin`, `~/bin`, `~/local/usr/bin`; `python3` on the webhost is a wrapper in `~/bin`). Checked under `env -i` (nothing at all, and only the HOME/PATH that `.pt/.htaccess` passes on): the real labels `localhost:tinyshell`, `whatwelo@localhost:mysql` and `cp1.uhcloud.com:cpanel` give the same login and secret as `auth foo`; `.pt/ts/config.php` (TinyShell) defines the same 9 constants, none empty, in all three environments. Backup: `Foo_Bar.php.bak-20261111b`.
- **Other:** `Strata/bin/check_email.pl` asks `auth` first (`imaps gmail.com --with-login`), `foo` as the fallback; run end to end by Chris. `Strata/bin/node/check_email.js` is an unported Perl copy, left alone. `auth` with `--with-login` is installed on the laptop and on cpbee.

## Not verified

- The webhost store works with cpbee down: Chris's claim, not checked.
- TinyShell (`.pt/ts/config.php`, calls `foo()` on every request) has not been opened in a browser since the redeploy, and `www/cmnet/www/index.php` (`foo($host.":web")`) has not been loaded through the web server: only `env -i` emulations of the web environment were run, not the real exec/gpg path as the web user. `myexpress.js` (node) could not be tested: there is no node on the webhost.
- `GetHosts.pm` also looks up `$router:zyxel`, which is not among the webhost's 8 labels (not new; a LAN-side lookup).

## Checked 2026-11-11 (TO_BE_RUN/DONE/webhost-regression-check-foo-bar.sh, read-only, after the deploy)

- Every language's library goes through `Foo_Bar_w.php`: confirmed from the perl, python and js sources (each runs `php-cli Foo_Bar_w.php`).
- For all 8 labels, bash `foo`, perl, python and the PHP shim return the same login and secret as `auth foo` (0 differences). Node: not tested (not installed).
- `cpanel.php` (cpinit cp1.uhcloud.com / whatwelove.org, get_subdomains) returned 25, as before.
- The five cron jobs (cleanmail, truncate_logs, 2fa_state_clean, update_ssl, geoipupdate-wrapper) do not refer to `Foo_Bar`, `user_*` or `cpanel.php`, so the deploy cannot have affected them.
- (fixed 2026-11-11) `ssh-wwl` reported "login failed" and exits whenever remote output contains the words "permission denied" (a false match in its expect pattern); it hid the output of one diagnostic run.

## Next (open items are GitHub issues: chrispollitt/POSIX#5 webhost, #14 tracking epic; `TO-DO.txt` is only a done-log)

1. Open TinyShell once in a browser (and the `index.php` page) to confirm the web path; delete `~/tmp-deploy` on the webhost.
2. Back up the webhost's `auth-service` key (no passphrase) and the cpbee one.
3. Move the remaining `Foo_Bar` callers (Strata: `fob-log-query.pl/.js`, `program_enterphone.sh`, `unit-query.pl`; WebApps: see the issues) to `auth get`.
4. A real Scheduled Task on cmlaptop and a crontab line on cpbee.
5. Phase 3 shims (tv suite `password_cmd`, `auth render --tmp`), then Phase 4 and 5.

## Notes

- Cloud sessions cannot run `gh pr create` (GraphQL is blocked); use `gh api repos/chrispollitt/POSIX/pulls ...`.
- The cloud clone fetches only `main`, so a hook may report unpushed commits when the remote branch exists; `git push -u origin BRANCH` or `git update-ref refs/remotes/origin/BRANCH SHA` fixes the local view.
- Webhost scripts are run from the laptop with `ssh-wwl` (see the `TO_BE_RUN` scripts); GitHub raw URLs can be cached for a few minutes after a push.
