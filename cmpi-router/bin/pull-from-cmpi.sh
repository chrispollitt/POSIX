#!/bin/bash
# pull-from-cmpi.sh - copy data and files from the old Raspberry Pi (cmpi) to this box (cpbee).
# Run ON cpbee as your normal user. Re-runnable: rsync only transfers changes, nothing on the Pi is
# modified, and nothing is deleted locally (no --delete). Services are NOT migrated, only data.
#
#   ./bin/pull-from-cmpi.sh list     dry run of the file copies: what would transfer
#   ./bin/pull-from-cmpi.sh home     /home/{chris,pi,miche,mesh}  -> $DEST/home/<user>
#   ./bin/pull-from-cmpi.sh web      /var/www/{html,6767}         -> $DEST/www
#   ./bin/pull-from-cmpi.sh root     root-only items (asks for the Pi's sudo password ONCE):
#                                all MariaDB databases, /etc reference configs, /var/mail,
#                                root-only files (/var/www/html/f, mesh tmp+backups, /root/bin)
#   ./bin/pull-from-cmpi.sh all      home + web + root
#   ./bin/pull-from-cmpi.sh verify   compare what is on the Pi with the local copy (dry-run summary)
#
# Needs rsync on both ends:  sudo apt install rsync   (cpbee)
# The dumps and /etc copy contain password hashes: they land in $DEST/root, mode 700.
set -u
set -o pipefail

SRC_HOST="${SRC_HOST:-chris@192.168.1.75}"        # cmpi's current LAN address
DEST="${DEST:-$HOME/cmpi-import}"
USERS_TO_COPY=(chris pi miche mesh)
WEB_DIRS=(/var/www/html /var/www/6767)
SSH_OPTS=(-o ConnectTimeout=10 -o ServerAliveInterval=30)

# Caches and tool state that are reproducible and bulky.
EXCLUDES=(
  --exclude=.vscode-server/ --exclude=.cache/ --exclude=.npm/ --exclude=.local/share/Trash/
  --exclude=node_modules/ --exclude=__pycache__/ --exclude='*.pyc'
)

say()  { printf '\n== %s\n' "$*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }
rs()   { rsync -aH --human-readable --info=stats1,progress2 -e "ssh ${SSH_OPTS[*]}" "$@"; }

preflight() {
  command -v rsync >/dev/null || die "rsync missing here: sudo apt install rsync"
  ssh -o BatchMode=yes "${SSH_OPTS[@]}" "$SRC_HOST" 'command -v rsync >/dev/null && hostname' \
    || die "cannot ssh to $SRC_HOST (key auth) or rsync missing on the Pi"
  mkdir -p "$DEST"
}

# rsync exit 23/24 = some files unreadable/vanished: report but keep going.
tolerant() {
  local rc=0; "$@" || rc=$?
  case $rc in
    0) ;;
    23|24) echo "NOTE: rsync finished with partial-transfer code $rc (unreadable or vanished files above)";;
    *) die "rsync failed with code $rc";;
  esac
}

do_home() {
  local dry=${1:-} u
  for u in "${USERS_TO_COPY[@]}"; do
    say "home: $u ${dry:+(dry run)}"
    mkdir -p "$DEST/home/$u"
    tolerant rs $dry "${EXCLUDES[@]}" "$SRC_HOST:/home/$u/" "$DEST/home/$u/"
  done
}

do_web() {
  local dry=${1:-} d
  for d in "${WEB_DIRS[@]}"; do
    say "web: $d ${dry:+(dry run)}"
    mkdir -p "$DEST/www/$(basename "$d")"
    tolerant rs $dry "$SRC_HOST:$d/" "$DEST/www/$(basename "$d")/"
  done
}

# One interactive sudo session on the Pi builds /tmp/cmpi-export-* owned by us; we fetch it and delete it.
do_root() {
  say "root-only items (enter the Pi's sudo password when asked)"
  local stamp rdir
  stamp=$(date +%Y%m%d-%H%M%S); rdir="/tmp/cmpi-export-$stamp"
  ssh -t "${SSH_OPTS[@]}" "$SRC_HOST" "sudo bash -c '
    set -e
    mkdir -m 700 $rdir
    echo \"dumping all databases...\"
    if command -v mariadb-dump >/dev/null; then D=mariadb-dump; else D=mysqldump; fi
    \$D --all-databases --single-transaction --routines --events --triggers | gzip > $rdir/all-databases.sql.gz
    echo \"collecting /etc reference configs...\"
    tar czf $rdir/etc-reference.tgz --ignore-failed-read -C / \
      etc/apache2 etc/php etc/mysql etc/postfix etc/dovecot etc/vsftpd.conf etc/inetutils-inetd.conf \
      etc/ntp.conf etc/hosts etc/hostname etc/fstab etc/crontab etc/cron.d etc/ssh/sshd_config \
      etc/letsencrypt etc/ssl/private etc/passwd etc/group etc/aliases etc/mailname \
      etc/phpmyadmin etc/postfixadmin etc/wordpress 2>/dev/null || true
    echo \"collecting /var/mail...\"
    tar czf $rdir/var-mail.tgz --ignore-failed-read -C / var/mail 2>/dev/null || true
    echo \"collecting root-only files (web f/, mesh tmp+backups, /root/bin)...\"
    tar czf $rdir/root-only-files.tgz --ignore-failed-read -C / \
      var/www/html/f home/mesh/tmp home/mesh/backups root/bin 2>/dev/null || true
    dpkg --get-selections > $rdir/packages.txt
    ( cd $rdir && sha256sum * > SHA256SUMS )
    chown -R ${SRC_HOST%@*} $rdir
  '" || die "root session on the Pi failed"
  mkdir -p "$DEST/root"; chmod 700 "$DEST/root"
  rs "$SRC_HOST:$rdir/" "$DEST/root/$stamp/" || die "could not fetch export"
  ( cd "$DEST/root/$stamp" && sha256sum -c SHA256SUMS ) || die "checksum mismatch, export NOT removed from the Pi ($rdir)"
  chmod -R go-rwx "$DEST/root"
  ssh "${SSH_OPTS[@]}" "$SRC_HOST" "rm -rf $rdir" && echo "removed $rdir on the Pi"
  ln -sfn "$stamp" "$DEST/root/latest"
  echo "root items in $DEST/root/$stamp:"; ls -lh "$DEST/root/$stamp"
}

do_verify() {
  say "verify: files the Pi has that the local copy lacks or differs on (dry run; 0 lines = in sync)"
  local u d out
  for u in "${USERS_TO_COPY[@]}"; do
    out=$(rsync -aHn --itemize-changes "${EXCLUDES[@]}" -e "ssh ${SSH_OPTS[*]}" "$SRC_HOST:/home/$u/" "$DEST/home/$u/" 2>/dev/null | grep -c '^[<>c]' )
    printf '  home/%-8s %s pending\n' "$u" "$out"
  done
  for d in "${WEB_DIRS[@]}"; do
    out=$(rsync -aHn --itemize-changes -e "ssh ${SSH_OPTS[*]}" "$SRC_HOST:$d/" "$DEST/www/$(basename "$d")/" 2>/dev/null | grep -c '^[<>c]')
    printf '  www/%-9s %s pending\n' "$(basename "$d")" "$out"
  done
  [ -e "$DEST/root/latest/all-databases.sql.gz" ] \
    && echo "  latest DB dump: $(readlink -f "$DEST/root/latest")" || echo "  no DB dump yet (run: root)"
}

mode=${1:-}
case $mode in
  list)   preflight; do_home -n; do_web -n;;
  home)   preflight; do_home;;
  web)    preflight; do_web;;
  root)   preflight; do_root;;
  all)    preflight; do_home; do_web; do_root; do_verify;;
  verify) preflight; do_verify;;
  *) sed -n '2,21p' "$0"; exit 1;;
esac
