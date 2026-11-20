#!/usr/bin/env bash
#
# create-groups.sh
#
# Make the groups of one or more group lists on the news server (configure-inn.sh has set it up):
# read-only by default ("n": the server takes an article for them from a feed only, which is how
# news-import adds the archive; nobody on the LAN can post into 1987).  Run on the server, as root
# or with sudo.  A group that exists is left alone.  A group list is one group per line, the name
# and then a description (which goes to the server's newsgroups file); # starts a comment; the same
# file is what news-import --groups reads.
#
# Usage:
#   sudo ./create-groups.sh [options] LIST...
#
# Options:
#   --flag F       the active-file flag: n (default, read-only), y (the LAN may post), m (moderated)
#   --creator S    the creator named in the log (default: news@HOSTNAME)
#   --print        print the ctlinnd commands and change nothing
#   -h | --help    show this header
#
set -euo pipefail
set -E
trap 'rc=$?; printf "ERROR: create-groups.sh stopped at line %s (exit %s): %s\n" "$LINENO" "$rc" "$BASH_COMMAND" >&2' ERR

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$here/../../mail-setup/lib/common.sh"
[ "${NEWS_SETUP_SUDO+set}" = set ] && SUDO="$NEWS_SETUP_SUDO"

DB="${NEWS_SETUP_DB:-/var/lib/news}"
CTLINND="${NEWS_SETUP_CTLINND:-/usr/lib/news/bin/ctlinnd}"
FLAG=n; CREATOR=""; PRINT=0; LISTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --flag)    FLAG="${2:?}"; shift 2 ;;
    --creator) CREATOR="${2:?}"; shift 2 ;;
    --print)   PRINT=1; shift ;;
    -h|--help) usage "$0"; exit 0 ;;
    -*) echo "unknown argument: $1" >&2; exit 2 ;;
    *)  LISTS+=("$1"); shift ;;
  esac
done
[ "${#LISTS[@]}" -gt 0 ] || die "name at least one group list (groups.d/classic.list)"
case "$FLAG" in y|n|m) ;; *) die "--flag: y, n or m" ;; esac
[ -n "$CREATOR" ] || CREATOR="news@$(hostname -f 2>/dev/null || hostname)"

as_news() {
  if [ "${NEWS_SETUP_AS_NEWS+set}" = set ]; then $NEWS_SETUP_AS_NEWS "$@"
  elif [ "$(id -u)" = 0 ]; then runuser -u news -- "$@"
  else $SUDO -u news "$@"; fi
}

made=0; had=0
for list in "${LISTS[@]}"; do
  [ -r "$list" ] || die "cannot read $list"
  while IFS= read -r line; do
    line=${line%%#*}
    name=${line%%[[:space:]]*}
    [ -n "$name" ] || continue
    desc=${line#"$name"}; desc=${desc#"${desc%%[![:space:]]*}"}
    case "$name" in *[!A-Za-z0-9.+_-]*) die "$list: '$name' is not a group name" ;; esac
    if [ "$PRINT" = 1 ]; then
      echo "ctlinnd newgroup $name $FLAG $CREATOR"
      continue
    fi
    if grep -q "^$name " "$DB/active" 2>/dev/null; then
      had=$((had + 1))
    else
      as_news "$CTLINND" newgroup "$name" "$FLAG" "$CREATOR" >/dev/null
      if [ -n "$desc" ] && ! grep -q "^$name[[:space:]]" "$DB/newsgroups" 2>/dev/null; then
        printf '%s\t%s\n' "$name" "$desc" | $SUDO tee -a "$DB/newsgroups" >/dev/null
      fi
      made=$((made + 1))
    fi
  done < "$list"
done
[ "$PRINT" = 1 ] || log "groups: $made created (flag $FLAG), $had already there"
