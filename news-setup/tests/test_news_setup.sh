#!/usr/bin/env bash
#
# test_news_setup.sh - tests for news-setup's scripts.
#
# Only what needs no root, no network and no INN: the config files configure-inn.sh writes (printed, and
# written into a sandbox with --config-only), its option checks and firewall plan, create-groups.sh with a
# fake ctlinnd, configure-tvmail-news.sh's edits of a tvmail.conf and its connection check against a fake
# server, and the importer's and downloader's own suites (test_news_import.py, test_fetch_archive.py).
# Installing INN2 for real is left to a run on the box itself.
#
# Exit 0 = all passed, 1 = something failed.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
N=$(CDPATH= cd -- "$here/.." && pwd)
INN="$N/scripts/configure-inn.sh"
GROUPS_SH="$N/scripts/create-groups.sh"
CLIENT="$N/scripts/configure-tvmail-news.sh"

PASS=0; FAIL=0; CUR=""
t()    { CUR="$*"; }
ok()   { PASS=$((PASS + 1)); printf '  ok    %s: %s\n' "$CUR" "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s: %s\n' "$CUR" "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
has()  { grep -qF -- "$2" "$1"; }

SANDBOX=$(mktemp -d)
BGPID=""
trap 'rm -rf "$SANDBOX"; [ -n "$BGPID" ] && kill "$BGPID" 2>/dev/null' EXIT
export NEWS_SETUP_SUDO=""
export NEWS_SETUP_IFACE=lan0
export NEWS_SETUP_LAN_CIDR=192.168.10.5/24
export LAN_PORT_DIR="$SANDBOX/no-router-setup"
PY=$(command -v python3)
OUT="$SANDBOX/out"
inn() { "$INN" --pathhost cpbee.cmnet "$@"; }

# --------------------------------------------------------------------------
t "syntax"
for s in configure-inn.sh create-groups.sh configure-tvmail-news.sh; do
  check "bash -n $s" 'bash -n "$N/scripts/$s"'
done
check "news-import and fetch-archive compile" '"$PY" -c "import sys; [compile(open(p).read(), p, \"exec\") for p in sys.argv[1:]]" "$N/bin/news-import" "$N/bin/fetch-archive"'
check "-h prints the usage" '"$INN" -h | grep -q "^Usage:"'

# --------------------------------------------------------------------------
t "inn.conf: only our keys change"
cat > "$SANDBOX/inn.conf" <<'EOF'
## inn.conf from the package
organization:           A poorly-installed InterNetNews site
pathhost:               localhost
#artcutoff:             10
mta:                    "/usr/sbin/sendmail -oi -oem %s"
maxartsize:             1000000
domain:                 example.org
verifycancels:          false
EOF
inn --print-config inn.conf "$SANDBOX/inn.conf" > "$SANDBOX/inn.out"
O="$SANDBOX/inn.out"
check "organization replaced, quoted" 'has "$O" "organization: \"LAN news\""'
check "pathhost replaced" 'has "$O" "pathhost: cpbee.cmnet" && ! has "$O" "pathhost:               localhost"'
check "artcutoff 0 added (the commented line is not a setting)" 'has "$O" "artcutoff: 0" && has "$O" "#artcutoff:             10"'
check "maxartsize raised" 'has "$O" "maxartsize: 4000000"'
check "verifycancels (no key in INN 2.7) is not added, and one an older run left goes" '! has "$O" "verifycancels"'
check "the other keys stay as they were" 'has "$O" "mta:                    \"/usr/sbin/sendmail -oi -oem %s\"" && has "$O" "domain:                 example.org"'
check "each key once" '[ "$(grep -c "^pathhost" "$O")" = 1 ] && [ "$(grep -c "^organization" "$O")" = 1 ]'
inn --organization "Chris at home" --print-config inn.conf "$SANDBOX/inn.conf" | grep -q 'organization: "Chris at home"'
check "--organization" '[ $? = 0 ]'

# --------------------------------------------------------------------------
t "readers.conf, incoming.conf, expire.ctl"
inn --print-config readers.conf > "$SANDBOX/readers.conf"
R="$SANDBOX/readers.conf"
check "the LAN subnet (normalised) and loopback may come in" 'has "$R" "hosts: \"127.0.0.1, ::1, 192.168.10.0/24\""'
check "read everything, post to lan.* only" 'has "$R" "read: \"*\"" && has "$R" "post: \"lan.*\""'
inn --allow 10.1.2.3/16 --allow 172.16.0.0/12 --print-config readers.conf | grep -q 'hosts: "127.0.0.1, ::1, 10.1.0.0/16, 172.16.0.0/12"'
check "--allow replaces the LAN default, repeatable" '[ $? = 0 ]'
inn --print-config incoming.conf > "$SANDBOX/incoming.conf"
check "the one peer is localhost" 'has "$SANDBOX/incoming.conf" "peer localhost" && has "$SANDBOX/incoming.conf" "hostname: \"127.0.0.1\"" && [ "$(grep -c "^peer" "$SANDBOX/incoming.conf")" = 1 ]'
inn --print-config expire.ctl > "$SANDBOX/expire.ctl"
check "nothing expires" 'has "$SANDBOX/expire.ctl" "*:A:never:never:never"'

# --------------------------------------------------------------------------
t "--config-only into a sandbox"
E="$SANDBOX/etc-news"; mkdir -p "$E"
cp "$SANDBOX/inn.conf" "$E/inn.conf"
export NEWS_SETUP_ETC="$E"
inn --config-only > "$OUT" 2>&1
check "exits 0 and says it only wrote files" '[ $? = 0 ] && has "$OUT" "--config-only"'
check "the four files are there" '[ -s "$E/inn.conf" ] && [ -s "$E/readers.conf" ] && [ -s "$E/incoming.conf" ] && [ -s "$E/expire.ctl" ]'
check "inn.conf was edited, not replaced" 'has "$E/inn.conf" "domain:                 example.org" && has "$E/inn.conf" "pathhost: cpbee.cmnet"'
check "the old inn.conf is backed up in BAK/" 'ls "$E"/BAK/inn.conf.bak-* >/dev/null 2>&1'
inn --config-only > "$OUT" 2>&1
check "a re-run changes nothing" 'has "$OUT" "inn.conf: unchanged" && has "$OUT" "readers.conf: unchanged" && ! has "$OUT" ": written"'
before=$(ls "$E"/BAK | wc -l)
for i in 1 2 3 4 5; do inn --pathhost "h$i.cmnet" --config-only >/dev/null 2>&1; sleep 1; done
check "only the 3 newest backups of a file are kept" '[ "$(ls "$E"/BAK/inn.conf.bak-* | wc -l)" = 3 ]'
check "  (and the last pathhost won)" 'has "$E/inn.conf" "pathhost: h5.cmnet"'
unset NEWS_SETUP_ETC

# --------------------------------------------------------------------------
t "option checks"
inn --pathhost "bad host" --print-config readers.conf > "$OUT" 2>&1
check "--pathhost with a space is refused" '[ $? != 0 ] && has "$OUT" "is not a host name"'
inn --allow 0.0.0.0/0 --print-config readers.conf > "$OUT" 2>&1
check "--allow 0.0.0.0/0 is refused" '[ $? != 0 ] && has "$OUT" "would let everyone read"'
inn --allow nonsense --print-config readers.conf > "$OUT" 2>&1
check "--allow must be an IPv4 CIDR" '[ $? != 0 ]'
inn --local-groups "lan.misc;rm" --print-config readers.conf > "$OUT" 2>&1
check "--local-groups with odd characters is refused" '[ $? != 0 ]'
inn --organization 'a"b' --print-config readers.conf > "$OUT" 2>&1
check "--organization with a quote is refused" '[ $? != 0 ]'
inn --print-config inn.conf > "$OUT" 2>&1
check "--print-config inn.conf needs the file" '[ $? != 0 ]'
inn --print-config nonsense > "$OUT" 2>&1
check "--print-config of an unknown file fails" '[ $? != 0 ]'
inn --bogus > "$OUT" 2>&1
check "an unknown option exits 2" '[ $? = 2 ]'

# --------------------------------------------------------------------------
t "firewall plan"
NFT="$SANDBOX/ruleset"
cat > "$NFT" <<'EOF'
table inet filter {
	chain input {
		type filter hook input priority filter; policy drop;
		iifname "lo" accept
		ct state established,related accept
	}
}
EOF
LAN_PORT_RULESET="$NFT" inn --firewall-plan > "$OUT" 2>&1
check "drop policy, no rule: the nft rule on lan0" 'grep -qx "nft add rule inet filter input iifname \"lan0\" tcp dport 119 accept" "$OUT"'
sed -i 's|ct state|tcp dport 119 accept\n\t\tct state|' "$NFT"
LAN_PORT_RULESET="$NFT" inn --firewall-plan > "$OUT" 2>&1
check "already accepted: nothing to do" 'has "$OUT" "nothing to open" && ! has "$OUT" "nft add rule"'

# --------------------------------------------------------------------------
t "quiet-daily-report.sh: the nightly report goes to a log, not to your inbox"
QD="$N/scripts/quiet-daily-report.sh"
QC="$SANDBOX/qcron"; QL="$SANDBOX/qlogrotate"; mkdir -p "$QC" "$QL"
printf 'SHELL=/bin/sh
15 4	* * * 	news	test -x /usr/lib/news/bin/news.daily && news.daily expireover lowmark delayrm
10 *	* * *	news	[ -x /usr/bin/rnews ] && rnews -U
' > "$QC/inn2"
export NEWS_SETUP_SUDO="" NEWS_SETUP_CRON="$QC" NEWS_SETUP_LOGROTATE="$QL" NEWS_SETUP_REPORT_LOG="$SANDBOX/daily-report.log"
"$QD" --print > "$OUT" 2>&1
check "--print shows the new line and changes nothing" 'has "$OUT" "news.daily nomail expireover lowmark delayrm >> $SANDBOX/daily-report.log 2>&1" && ! has "$QC/inn2" "nomail"'
"$QD" > "$OUT" 2>&1
check "the job says nomail and appends to the log" '[ $? = 0 ] && has "$QC/inn2" "news.daily nomail expireover lowmark delayrm >> $SANDBOX/daily-report.log 2>&1"'
check "the other job is untouched" 'has "$QC/inn2" "rnews -U" && [ "$(grep -c nomail "$QC/inn2")" = 1 ]'
check "the cron file was backed up" 'ls "$QC/BAK/inn2.bak-"* >/dev/null 2>&1'
check "logrotate: monthly, 12 kept" 'has "$QL/inn-daily-report" "monthly" && has "$QL/inn-daily-report" "rotate 12" && has "$QL/inn-daily-report" "$SANDBOX/daily-report.log {"'
"$QD" > "$OUT" 2>&1
check "a re-run changes nothing" 'has "$OUT" "already written to a log" && [ "$(ls "$QC/BAK" | wc -l)" = 1 ]'
"$QD" --undo > "$OUT" 2>&1
check "--undo brings the mail back" '[ $? = 0 ] && ! has "$QC/inn2" "nomail" && has "$OUT" "mailed again"'
rm -f "$QC/inn2"; "$QD" > "$OUT" 2>&1
check "no cron file: says so, fails" '[ $? != 0 ] && has "$OUT" "is not here"'
unset NEWS_SETUP_SUDO NEWS_SETUP_CRON NEWS_SETUP_LOGROTATE NEWS_SETUP_REPORT_LOG
export NEWS_SETUP_SUDO=""

# --------------------------------------------------------------------------
t "create-groups.sh with a fake ctlinnd"
DB="$SANDBOX/db"; mkdir -p "$DB"
cat > "$SANDBOX/ctlinnd" <<EOF
#!/bin/sh
# fake: newgroup NAME FLAG CREATOR -> a line in the active file, and a log
echo "\$@" >> "$SANDBOX/ctlinnd.log"
[ "\$1" = newgroup ] && echo "\$2 0000000000 0000000001 \$3" >> "$DB/active"
exit 0
EOF
chmod +x "$SANDBOX/ctlinnd"
export NEWS_SETUP_DB="$DB" NEWS_SETUP_CTLINND="$SANDBOX/ctlinnd" NEWS_SETUP_AS_NEWS=""
printf '# a list\nnet.jokes   Humor, the old way\ncomp.lang.c\n\nbad.group  # a comment after\n' > "$SANDBOX/g.list"
"$GROUPS_SH" --creator news@cpbee "$SANDBOX/g.list" > "$OUT" 2>&1
check "creates each group read-only" '[ $? = 0 ] && has "$SANDBOX/ctlinnd.log" "newgroup net.jokes n news@cpbee" && has "$SANDBOX/ctlinnd.log" "newgroup comp.lang.c n news@cpbee" && has "$SANDBOX/ctlinnd.log" "newgroup bad.group n news@cpbee"'
check "  and says how many" 'has "$OUT" "3 created (flag n), 0 already there"'
check "descriptions go to the newsgroups file" 'grep -q "^net.jokes	Humor, the old way$" "$DB/newsgroups" && ! grep -q "^comp.lang.c" "$DB/newsgroups"'
: > "$SANDBOX/ctlinnd.log"
"$GROUPS_SH" "$SANDBOX/g.list" > "$OUT" 2>&1
check "a re-run creates nothing" '[ ! -s "$SANDBOX/ctlinnd.log" ] && has "$OUT" "0 created (flag n), 3 already there"'
"$GROUPS_SH" --flag y --print "$SANDBOX/g.list" > "$OUT" 2>&1
check "--print shows the commands and runs none" 'grep -q "^ctlinnd newgroup net.jokes y news@" "$OUT" && [ ! -s "$SANDBOX/ctlinnd.log" ]'
printf 'bad!name  x\n' > "$SANDBOX/bad.list"
"$GROUPS_SH" "$SANDBOX/bad.list" > "$OUT" 2>&1
check "a bad group name is refused" '[ $? != 0 ] && has "$OUT" "is not a group name"'
"$GROUPS_SH" --flag q "$SANDBOX/g.list" > "$OUT" 2>&1
check "--flag must be y, n or m" '[ $? != 0 ]'
"$GROUPS_SH" > "$OUT" 2>&1
check "no list is an error" '[ $? != 0 ]'
check "the shipped classic.list is all valid group lines" '"$GROUPS_SH" --print "$N/groups.d/classic.list" | wc -l | grep -qE "^[0-9]{2,}"'
unset NEWS_SETUP_DB NEWS_SETUP_CTLINND NEWS_SETUP_AS_NEWS

# --------------------------------------------------------------------------
t "configure-tvmail-news.sh"
C="$SANDBOX/tvmail.conf"
export TVMAIL_CONF="$C"
"$CLIENT" --no-check --host cpbee --subscribed lan.misc,comp.os.linux > "$OUT" 2>&1
check "a new file: exit 0" '[ $? = 0 ]'
check "  [services] order has mail first, then news" 'has "$C" "[services]" && has "$C" "order = mail, news"'
check "  [news] has host, port, window, subscribed" 'has "$C" "host = cpbee" && has "$C" "port = 119" && has "$C" "window = 500" && has "$C" "subscribed = lan.misc, comp.os.linux"'
cat > "$C" <<'EOF'
# my tvmail.conf
[service]
mode = remote   # imap
[services]
# the order of the pane
order = mail, floyd
[news]
host = oldhost
[ui]
check = 300
EOF
"$CLIENT" --no-check --host cpbee --port 1119 --window 200 > "$OUT" 2>&1
check "an existing file: comments and other sections stay" 'has "$C" "# my tvmail.conf" && has "$C" "mode = remote   # imap" && has "$C" "# the order of the pane" && has "$C" "check = 300"'
check "  news is added after the services already there" 'has "$C" "order = mail, floyd, news"'
check "  the [news] keys are replaced in place, not added twice" '[ "$(grep -c "^host" "$C")" = 1 ] && has "$C" "host = cpbee" && has "$C" "port = 1119" && has "$C" "window = 200"'
check "  and the file was backed up" 'ls "$SANDBOX"/BAK/tvmail.conf.bak-* >/dev/null 2>&1'
"$CLIENT" --no-check --host cpbee --port 1119 --window 200 > "$OUT" 2>&1
check "a re-run does not repeat news in the order" '[ "$(grep -c "^order = mail, floyd, news$" "$C")" = 1 ]'
"$CLIENT" --host 127.0.0.1 --port 1 > "$OUT" 2>&1
check "a closed port fails the check, saying so" '[ $? != 0 ] && has "$OUT" "cannot connect"'
"$CLIENT" --host "bad host" --no-check > "$OUT" 2>&1
check "--host with a space is refused" '[ $? != 0 ]'
# the check against a server that greets and lists groups
"$PY" - "$SANDBOX/port" <<'PYEOF' &
import socket, sys
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(1)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
c, _ = s.accept(); f = c.makefile("rwb", buffering=0)
f.write(b"200 fake ready\r\n")
for line in iter(f.readline, b""):
    w = line.strip().upper()
    if w == b"MODE READER": f.write(b"200 reader\r\n")
    elif w.startswith(b"LIST"): f.write(b"215 ok\r\nlan.misc 3 1 y\r\nlan.talk 0 1 y\r\n.\r\n")
    elif w == b"QUIT": break
PYEOF
BGPID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$SANDBOX/port" ] && break; sleep 0.3; done
"$CLIENT" --host 127.0.0.1 --port "$(cat "$SANDBOX/port")" > "$OUT" 2>&1
check "a live server: greeting and group count shown" '[ $? = 0 ] && has "$OUT" "2 groups" && has "$OUT" "posting allowed"'
unset TVMAIL_CONF

# --------------------------------------------------------------------------
t "the importer and the downloader"
"$PY" "$here/test_news_import.py" > "$OUT" 2>&1
check "test_news_import.py" '[ $? = 0 ] || { tail -20 "$OUT"; false; }'
"$PY" "$here/test_fetch_archive.py" > "$OUT" 2>&1
check "test_fetch_archive.py" '[ $? = 0 ] || { tail -20 "$OUT"; false; }'

# --------------------------------------------------------------------------
t "the Usenet Archives sampler (userscript core)"
NODE=$(command -v node || command -v nodejs || true)
if [ -z "$NODE" ]; then
  echo "  skip  no node here: bin/usenetarchives-sample.user.js's core is not tested"
else
  OUTW="$SANDBOX/sample.mbox"; command -v cygpath >/dev/null 2>&1 && OUTW=$(cygpath -w "$SANDBOX/sample.mbox")
  JSW="$here/test_usenet_sample.js"; command -v cygpath >/dev/null 2>&1 && JSW=$(cygpath -w "$JSW")
  "$NODE" "$JSW" "$OUTW" > "$OUT" 2>&1
  check "test_usenet_sample.js" '[ $? = 0 ] || { tail -20 "$OUT"; false; }'
  "$N/bin/news-import" --groups "$N/groups.d/classic.list" --dry-run "$SANDBOX/sample.mbox" > "$OUT" 2>&1
  check "news-import reads what the sampler writes (both articles; each gets a Path)" 'has "$OUT" "read 2: would offer 2 (2 repaired)"'
fi

echo
echo "news-setup: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
