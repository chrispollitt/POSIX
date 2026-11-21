#!/usr/bin/env bash
#
# test_lists_setup.sh - tests for lists-setup's scripts.
#
# Only what needs no root, no network and no mail software: the files configure-lists.sh would write (printed), its
# option checks, and the whole install run in a sandbox against fake postconf / postfix / doveconf / dovecot / sievec
# (re-runs, backups, the two rollbacks, the missing-prerequisite messages), configure-tvmail-lists.sh's edits of a
# tvmail.conf, and the Python suite (listlib, listserv, listctl).  Installing mlmmj and reloading Postfix and Dovecot for
# real is left to a run on the box itself.
#
# Exit 0 = all passed, 1 = something failed.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
N=$(CDPATH= cd -- "$here/.." && pwd)
CFG="$N/scripts/configure-lists.sh"
CLIENT="$N/scripts/configure-tvmail-lists.sh"

PASS=0; FAIL=0; CUR=""
t()    { CUR="$*"; }
ok()   { PASS=$((PASS + 1)); printf '  ok    %s: %s\n' "$CUR" "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s: %s\n' "$CUR" "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
has()  { grep -qF -- "$2" "$1"; }

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
PY=$(command -v python3)
OUT="$SANDBOX/out"

# --------------------------------------------------------------------------
t "syntax"
for s in configure-lists.sh configure-tvmail-lists.sh; do
  check "bash -n $s" 'bash -n "$N/scripts/$s"'
done
check "listserv, listctl and listlib compile" '"$PY" -c "import sys; [compile(open(p).read(), p, \"exec\") for p in sys.argv[1:]]" "$N/bin/listserv" "$N/bin/listctl" "$N/bin/listlib.py"'
check "-h prints the usage" 'bash "$CFG" -h | grep -q "^Usage:"'

# --------------------------------------------------------------------------
t "what it would write"
pc() { bash "$CFG" --domain cpbee.cmnet --print-config "$@"; }
pc lists.conf > "$OUT"
check "lists.conf: the domain, the address and the spool" 'has "$OUT" "DOMAIN = cpbee.cmnet" && has "$OUT" "ADDRESS = listserv@cpbee.cmnet" && has "$OUT" "SPOOL = /var/spool/mlmmj"'
pc postfix-master > "$OUT"
check "master.cf: mlmmj runs mlmmj-receive for the list directory in \$nexthop, as the mlmmj user" 'has "$OUT" "mlmmj unix - n n - - pipe flags=ORhu user=mlmmj argv=/usr/bin/mlmmj-receive -F -L /var/spool/mlmmj/\$nexthop"'
check "master.cf: listserv gets the envelope sender" 'has "$OUT" "listserv unix - n n - - pipe flags=R user=mlmmj argv=/usr/local/bin/listserv --sender=\${sender}"'
pc postfix-main > "$OUT"
check "main.cf: the two tables are added, the delimiter is +" 'has "$OUT" "hash:/var/spool/mlmmj/virtual" && has "$OUT" "hash:/var/spool/mlmmj/transport" && has "$OUT" "recipient_delimiter = +"'
pc sieve-script > "$OUT"
check "sieve: files by List-Id into Lists/NAME, creates it, stops" 'has "$OUT" "<([a-z0-9._-]+)\\\\.cpbee\\\\.cmnet>" && has "$OUT" "fileinto :create \"Lists/\${1}\";" && has "$OUT" "stop;" && has "$OUT" "\"variables\""'
bash "$CFG" --domain a.b --prefix Mail --separator . --print-config sieve-script > "$OUT"
check "sieve: another prefix and separator" 'has "$OUT" "Mail.\${1}"'
pc dovecot-dropin --dovecot-version 2.4 > "$OUT"
check "dovecot 2.4: a before storage" 'has "$OUT" "sieve_script lists {" && has "$OUT" "type = before" && has "$OUT" "path = /etc/dovecot/sieve-before.d"'
pc dovecot-dropin --dovecot-version 2.3.21 > "$OUT"
check "dovecot 2.3: sieve_before in plugin {}" 'has "$OUT" "plugin {" && has "$OUT" "sieve_before = /etc/dovecot/sieve-before.d"'
pc cron > "$OUT"
check "cron: mlmmj-maintd for every list" 'has "$OUT" "*/10 * * * * mlmmj /usr/bin/mlmmj-maintd -F -d /var/spool/mlmmj"'

# --------------------------------------------------------------------------
t "option checks"
check "bad domain" '! bash "$CFG" --domain "bad domain" --print-config cron >/dev/null 2>&1'
check "bad list name" '! bash "$CFG" --domain a.b --list "Bad Name" --print-config cron >/dev/null 2>&1'
check "bad owner" '! bash "$CFG" --domain a.b --owner nobody --print-config cron >/dev/null 2>&1'
check "bad separator" '! bash "$CFG" --domain a.b --separator x --print-config sieve-script >/dev/null 2>&1'
check "dovecot-dropin needs the version" '! pc dovecot-dropin >/dev/null 2>&1'
check "unknown option" '! bash "$CFG" --nonsense >/dev/null 2>&1'
check "unknown --print-config" '! pc nothing >/dev/null 2>&1'

# --------------------------------------------------------------------------
# a sandbox box: fake postconf (parameters in a file), postfix, doveconf, dovecot, sievec, mlmmj tools
t "the whole run, in a sandbox"
BOX="$SANDBOX/box"; FB="$SANDBOX/fakebin"
mkdir -p "$BOX/postfix" "$BOX/dovecot/conf.d" "$BOX/bin" "$BOX/lib" "$BOX/etc" "$BOX/cron" "$BOX/spool" "$FB"
echo "# main.cf" > "$BOX/postfix/main.cf"; echo "# master.cf" > "$BOX/postfix/master.cf"
cat > "$BOX/pc.state" <<EOF
recipient_delimiter=+
propagate_unmatched_extensions=canonical, virtual
mailbox_command=/usr/lib/dovecot/dovecot-lda -f "\$SENDER" -a "\$RECIPIENT"
myhostname=cpbee.cmnet
mail_version=3.9.1
virtual_alias_maps=\$virtual_maps
transport_maps=
config_directory=$BOX/postfix
EOF
cat > "$FB/postconf" <<EOF
#!$PY
import os, sys
st = os.environ["FAKE_PC_STATE"]
rows = dict(l.rstrip("\n").split("=", 1) for l in open(st) if "=" in l)
a = sys.argv[1:]
def save():
    open(st, "w").write("".join("%s=%s\n" % kv for kv in rows.items()))
if a[:1] == ["-h"]:
    for k in a[1:]:
        print(rows.get(k, ""))
elif a[:1] == ["-e"]:
    for kv in a[1:]:
        k, v = kv.split("=", 1); rows[k] = v
    save()
elif a[:1] == ["-M"]:
    k = a[1].split("=", 1)
    if len(k) == 2:
        rows["master:" + k[0]] = k[1]; save()
    elif "master:" + k[0] in rows:
        print(rows["master:" + k[0]])
EOF
cat > "$FB/postfix" <<EOF
#!$PY
import os, sys
open(os.environ["FAKE_CALLS"], "a").write("postfix " + " ".join(sys.argv[1:]) + "\n")
if sys.argv[1:2] == ["check"] and os.path.exists(os.environ["FAKE_PF_FAIL"]):
    sys.stderr.write("postfix: fatal: bad main.cf\n"); sys.exit(1)
EOF
cat > "$FB/postmap" <<EOF
#!$PY
import os, sys
open(os.environ["FAKE_CALLS"], "a").write("postmap " + " ".join(sys.argv[1:]) + "\n")
EOF
cat > "$FB/doveconf" <<EOF
#!$PY
import os, sys
if sys.argv[1:2] == ["-n"] and os.path.exists(os.environ["FAKE_DC_FAIL"]):
    sys.stderr.write("doveconf: Fatal: Error in configuration file: bad setting\n"); sys.exit(1)
if sys.argv[1:2] == ["-n"]:
    print("mail_driver = mbox")
EOF
cat > "$FB/dovecot" <<EOF
#!$PY
print("2.4.1-4 (7d8c0e5759)")
EOF
cat > "$FB/sievec" <<EOF
#!$PY
import sys
open(sys.argv[1] + "c", "w").write("compiled")
EOF
cat > "$FB/mlmmj-sub" <<EOF
#!/bin/sh
exit 0
EOF
for f in postconf postfix postmap doveconf dovecot sievec mlmmj-sub; do chmod +x "$FB/$f"; done
export FAKE_PC_STATE="$BOX/pc.state" FAKE_CALLS="$BOX/calls.log" FAKE_PF_FAIL="$BOX/pf-fail" FAKE_DC_FAIL="$BOX/dc-fail"
export LISTS_SETUP_SUDO="" LISTS_SETUP_ANY_OS=1
export LISTS_SETUP_POSTCONF="$FB/postconf" LISTS_SETUP_POSTFIX="$FB/postfix" LISTS_SETUP_DOVECONF="$FB/doveconf"
export LISTS_SETUP_DOVECOT="$FB/dovecot" LISTS_SETUP_SIEVEC="$FB/sievec"
export LISTS_SETUP_CONFDIR="$BOX/etc" LISTS_SETUP_BINDIR="$BOX/bin" LISTS_SETUP_LIBDIR="$BOX/lib"
export LISTS_SETUP_DOVECOT_ETC="$BOX/dovecot" LISTS_SETUP_CRON="$BOX/cron" LISTS_SETUP_SPOOL="$BOX/spool"
export LISTS_SETUP_MLMMJ_BIN="$FB"
export PATH="$FB:$PATH"
run() { bash "$CFG" --domain cpbee.cmnet --no-install --no-reload "$@"; }

run --list "alpha:The first list" --list beta --owner chris@cpbee.cmnet > "$OUT" 2>&1; rc=$?
check "exit 0" '[ $rc = 0 ] || { cat "$OUT"; false; }'
PCS="$BOX/pc.state"
check "listserv, listctl and listlib are installed" '[ -f "$BOX/bin/listserv" ] && [ -f "$BOX/bin/listctl" ] && [ -f "$BOX/lib/listlib.py" ]'
check "lists.conf written" 'has "$BOX/etc/lists.conf" "DOMAIN = cpbee.cmnet" && has "$BOX/etc/lists.conf" "MLMMJ_BIN = $FB"'
check "virtual_alias_maps keeps its old value and gains the table" 'has "$PCS" "virtual_alias_maps=\$virtual_maps, hash:$BOX/spool/virtual"'
check "transport_maps (was empty) is just the table" 'has "$PCS" "transport_maps=hash:$BOX/spool/transport"'
check "recipient_delimiter and propagate stay as they were" 'has "$PCS" "recipient_delimiter=+" && has "$PCS" "propagate_unmatched_extensions=canonical, virtual"'
check "the per-service limits" 'has "$PCS" "mlmmj_destination_recipient_limit=1" && has "$PCS" "listserv_destination_recipient_limit=1"'
check "master.cf services set" 'has "$PCS" "master:mlmmj/unix=mlmmj unix - n n - - pipe flags=ORhu user=mlmmj argv=$FB/mlmmj-receive -F -L $BOX/spool/\$nexthop" && has "$PCS" "master:listserv/unix=listserv unix - n n - - pipe flags=R user=mlmmj argv=$BOX/bin/listserv --sender=\${sender}"'
check "the tables are there and were postmapped" '[ -f "$BOX/spool/virtual" ] && [ -f "$BOX/spool/transport" ] && has "$FAKE_CALLS" "postmap $BOX/spool/virtual"'
check "the tables name the lists" 'grep -q "alpha@cpbee.cmnet" "$BOX/spool/virtual" && grep -q "mlmmj:beta" "$BOX/spool/transport" && grep -q "listserv:" "$BOX/spool/transport"'
check "postfix check ran" 'has "$FAKE_CALLS" "postfix check"'
check "the lists were made, with the owner" '[ -d "$BOX/spool/alpha/control" ] && has "$BOX/spool/beta/control/owner" "chris@cpbee.cmnet" && has "$BOX/spool/alpha/control/description" "The first list"'
check "Sieve: the global script, compiled" 'has "$BOX/dovecot/sieve-before.d/90-lists.sieve" "fileinto :create \"Lists/\${1}\";" && [ -f "$BOX/dovecot/sieve-before.d/90-lists.sievec" ]'
check "Dovecot 2.4 drop-in" 'has "$BOX/dovecot/conf.d/96-lists-setup-sieve.conf" "sieve_script lists {"'
check "cron entry" 'has "$BOX/cron/lists-setup" "mlmmj-maintd -F -d $BOX/spool"'
check "main.cf and master.cf were backed up" 'ls "$BOX/postfix/BAK/main.cf.bak-"* >/dev/null 2>&1 && ls "$BOX/postfix/BAK/master.cf.bak-"* >/dev/null 2>&1'

t "re-running changes nothing"
cp "$PCS" "$SANDBOX/pc.before"
run --list "alpha:The first list" > "$OUT" 2>&1; rc=$?
check "exit 0" '[ $rc = 0 ]'
check "postconf state is unchanged (no table added twice)" 'cmp -s "$PCS" "$SANDBOX/pc.before"'
check "says so" 'has "$OUT" "virtual_alias_maps: has hash:" && has "$OUT" "unchanged" && has "$OUT" "list        : alpha exists"'
check "the Sieve script and drop-in were not rewritten" 'has "$OUT" "90-lists.sieve: unchanged" && has "$OUT" "96-lists-setup-sieve.conf: unchanged"'

t "rollbacks"
touch "$FAKE_PF_FAIL"
run > "$OUT" 2>&1; rc=$?
check "a failing postfix check stops it and says what Postfix said" '[ $rc != 0 ] && has "$OUT" "postfix check rejected" && has "$OUT" "bad main.cf"'
rm -f "$FAKE_PF_FAIL"
rm -f "$BOX/dovecot/conf.d/96-lists-setup-sieve.conf"; rm -rf "$BOX/dovecot/sieve-before.d"
touch "$FAKE_DC_FAIL"
run > "$OUT" 2>&1; rc=$?
check "a doveconf that rejects the drop-in stops it, and the drop-in is gone again" '[ $rc != 0 ] && has "$OUT" "doveconf rejected" && [ ! -e "$BOX/dovecot/conf.d/96-lists-setup-sieve.conf" ]'
rm -f "$FAKE_DC_FAIL"

t "prerequisites"
cp "$PCS" "$SANDBOX/pc.good"
sed -i 's|^mailbox_command=.*|mailbox_command=|' "$PCS"
run > "$OUT" 2>&1; rc=$?
check "no dovecot-lda: names configure-sieve.sh" '[ $rc != 0 ] && has "$OUT" "configure-sieve.sh"'
cp "$SANDBOX/pc.good" "$PCS"
LISTS_SETUP_SIEVEC=/nonexistent/sievec run > "$OUT" 2>&1; rc=$?
check "no Pigeonhole: names configure-sieve.sh" '[ $rc != 0 ] && has "$OUT" "configure-sieve.sh"'
LISTS_SETUP_POSTCONF=/nonexistent/postconf run > "$OUT" 2>&1; rc=$?
check "no Postfix: names configure-sendmail-relay.sh" '[ $rc != 0 ] && has "$OUT" "configure-sendmail-relay.sh"'
sed -i 's|^recipient_delimiter=.*|recipient_delimiter=-|' "$PCS"
run > "$OUT" 2>&1; rc=$?
check "another recipient_delimiter is refused in words" '[ $rc != 0 ] && has "$OUT" "recipient_delimiter is"'
cp "$SANDBOX/pc.good" "$PCS"

# --------------------------------------------------------------------------
t "configure-tvmail-lists.sh"
if [ -f "$CLIENT" ]; then
  export TVMAIL_CONF="$SANDBOX/tvmail.conf"
  cat > "$TVMAIL_CONF" <<'EOF'
# my config
[service]
mode = remote

[imap]
host = cpbee
user = chris
EOF
  bash "$CLIENT" --address listserv@cpbee.cmnet --realname "Chris P" > "$OUT" 2>&1; rc=$?
  check "exit 0" '[ $rc = 0 ] || { cat "$OUT"; false; }'
  check "[lists] written, the rest kept" 'has "$TVMAIL_CONF" "[lists]" && has "$TVMAIL_CONF" "address = listserv@cpbee.cmnet" && has "$TVMAIL_CONF" "realname = Chris P" && has "$TVMAIL_CONF" "# my config" && has "$TVMAIL_CONF" "host = cpbee"'
  check "lists in [services] order" 'grep -q "^order *= *mail, lists" "$TVMAIL_CONF"'
  check "backed up" 'ls "$SANDBOX/BAK/tvmail.conf"* >/dev/null 2>&1 || ls "$SANDBOX"/BAK/* >/dev/null 2>&1'
  bash "$CLIENT" --address listserv@cpbee.cmnet --realname "Ann Lee" > "$OUT" 2>&1
  check "re-run replaces, does not add: one [lists], one order line, the new name" '[ "$(grep -c "^\[lists\]" "$TVMAIL_CONF")" = 1 ] && [ "$(grep -c "^order" "$TVMAIL_CONF")" = 1 ] && has "$TVMAIL_CONF" "realname = Ann Lee" && ! has "$TVMAIL_CONF" "Chris P"'
  check "bad address refused" '! bash "$CLIENT" --address nonsense >/dev/null 2>&1'
  printf '[service]\nmode = local\n' > "$TVMAIL_CONF"
  bash "$CLIENT" --address listserv@cpbee.cmnet > "$OUT" 2>&1
  check "local mode: written, with a warning that Lists needs remote mode" 'has "$TVMAIL_CONF" "[lists]" && grep -qi "remote mode" "$OUT"'
else
  bad "configure-tvmail-lists.sh is missing"
fi

# --------------------------------------------------------------------------
t "the Python suite"
# the sandbox's LISTS_SETUP_* settings (and fake programs on PATH) are not the Python suite's: it makes its own
for v in $(env | sed -n 's/^\(LISTS_SETUP_[A-Z_]*\)=.*/\1/p') FAKE_PC_STATE FAKE_CALLS FAKE_PF_FAIL FAKE_DC_FAIL; do unset "$v"; done
PATH=${PATH#"$FB:"}
"$PY" "$here/test_lists.py" > "$OUT" 2>&1
check "test_lists.py (listlib, listserv, listctl)" 'tail -3 "$OUT" | grep -q "^OK"'
[ -s "$OUT" ] && ! tail -3 "$OUT" | grep -q "^OK" && cat "$OUT"

echo
echo "lists-setup: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
