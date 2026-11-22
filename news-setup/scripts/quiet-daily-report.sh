#!/usr/bin/env bash
#
# quiet-daily-report.sh
#
# INN's cron job runs news.daily every night, and news.daily MAILS its report ("cpbee Daily Usenet report for ...") to the
# news master, which here is root and so you.  A server nobody is watching does not need a mail a day.  This changes
# the cron job so that the report is appended to /var/log/news/daily-report.log instead (news.daily's own "nomail"
# keyword plus a redirect), and rotates that log monthly (12 kept, compressed), so a monthly digest can read the month's
# reports.  Nothing else about the job changes.
#
# Usage:   sudo ./quiet-daily-report.sh [--undo] [--print]
#   --undo    put the newest BAK copy of the cron file back (the mail comes again)
#   --print   show what would change; change nothing
#
# Re-runnable (a job that already says "nomail" is left alone).  The cron file is a package file (inn2): it is backed up
# to BAK/ beside it first, the 3 newest kept.
set -euo pipefail

CRON="${NEWS_SETUP_CRON:-/etc/cron.d}/inn2"
LOGROTATE="${NEWS_SETUP_LOGROTATE:-/etc/logrotate.d}/inn-daily-report"
LOG="${NEWS_SETUP_REPORT_LOG:-/var/log/news/daily-report.log}"
SUDO="${NEWS_SETUP_SUDO-}"; [ "${NEWS_SETUP_SUDO+set}" = set ] || { [ "$(id -u)" = 0 ] || SUDO=sudo; }
UNDO=0; PRINT=0
for a in "$@"; do
  case "$a" in --undo) UNDO=1 ;; --print) PRINT=1 ;; -h|--help) sed -n 3,18p "$0"; exit 0 ;; *) echo "unknown option $a" >&2; exit 2 ;; esac
done
log()  { printf '%s\n' "$*"; }
die()  { printf 'quiet-daily-report: %s\n' "$*" >&2; exit 1; }
backup_keep3() {
  local f="$1" d b; d=$(dirname "$f")/BAK; b=$(basename "$f")
  [ -e "$f" ] || return 0
  $SUDO mkdir -p "$d"; $SUDO cp -p "$f" "$d/$b.bak-$(date +%Y%m%d-%H%M%S)"
  # shellcheck disable=SC2012
  ls -1t "$d/$b".bak-* 2>/dev/null | tail -n +4 | while IFS= read -r old; do $SUDO rm -f "$old"; done
}

if [ "$UNDO" = 1 ]; then
  d=$(dirname "$CRON")/BAK
  # shellcheck disable=SC2012
  last=$(ls -1t "$d/$(basename "$CRON")".bak-* 2>/dev/null | head -1 || true)
  [ -n "$last" ] || die "no backup of $CRON in $d"
  if [ "$PRINT" = 1 ]; then log "would put $last back as $CRON"; exit 0; fi
  $SUDO cp -p "$last" "$CRON"; log "$CRON: back from $last (the daily report is mailed again)"; exit 0
fi

[ -f "$CRON" ] || die "$CRON is not here (is the inn2 package installed?)"
if grep -qE '^[^#].*news\.daily.* nomail' "$CRON"; then
  log "$CRON: the daily report is already written to a log, not mailed"
else
  grep -qE '^[^#].*news\.daily' "$CRON" || die "$CRON has no news.daily job to change"
  tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
  sed -E "s|^([^#].*news\\.daily) (.*)\$|\\1 nomail \\2 >> $LOG 2>\&1|" "$CRON" > "$tmp"
  if [ "$PRINT" = 1 ]; then log "the news.daily line would become:"; grep -E 'news\.daily' "$tmp" | sed 's/^/  /'
  else
    backup_keep3 "$CRON"
    $SUDO install -m 644 "$tmp" "$CRON"
    log "$CRON: news.daily now writes its report to $LOG (no mail)"
  fi
fi

want=$(cat <<EOF
# monthly rotation of the news.daily report log (see quiet-daily-report.sh); 12 months kept
$LOG {
    monthly
    rotate 12
    missingok
    notifempty
    compress
    delaycompress
    create 644 news news
    su news news
}
EOF
)
if [ "$PRINT" = 1 ]; then log "and $LOGROTATE would hold:"; printf '%s\n' "$want" | sed 's/^/  /'; exit 0; fi
tmp2=$(mktemp); printf '%s\n' "$want" > "$tmp2"
if $SUDO cmp -s "$tmp2" "$LOGROTATE" 2>/dev/null; then log "$LOGROTATE: unchanged"
else $SUDO install -d -m 755 "$(dirname "$LOGROTATE")"; $SUDO install -m 644 "$tmp2" "$LOGROTATE"; log "$LOGROTATE: written"; fi
rm -f "$tmp2"
