# shellcheck shell=bash
# lib/common.sh - shared helpers for the mail-setup scripts.  Source it:
#
#     here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
#     . "$here/../lib/common.sh"
#
# Honours $ASSUME ("" = ask, "yes", "no") for ask(); sets OS / PKG / SUDO.

log()  { printf '  %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
step() { echo; echo "== $* =="; }

# print a script's leading comment block (for -h/--help)
usage() { sed -n '2,/^set -euo pipefail/p' "$1" | sed 's/^# \{0,1\}//; $d'; }

# ask "question" [default Y|N] -> 0 (yes) / 1 (no).  $ASSUME short-circuits.
ask() {
  [ "${ASSUME:-}" = yes ] && { log "$1 -> yes (--yes)"; return 0; }
  [ "${ASSUME:-}" = no ]  && { log "$1 -> no (--assume-no)"; return 1; }
  def="${2:-Y}"; suf="[Y/n]"; [ "$def" = N ] && suf="[y/N]"
  printf '%s %s ' "$1" "$suf"
  ans=""; read -r ans || true; : "${ans:=$def}"
  case "$ans" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# readval "prompt" "default" -> echoes the chosen value (stdout only).
readval() {
  printf '%s [%s]: ' "$1" "$2" >&2
  ans=""; read -r ans || true; : "${ans:=$2}"
  printf '%s\n' "$ans"
}

readsecret() {   # readsecret "prompt" -> echoes the typed value (stdout only)
  printf '%s: ' "$1" >&2
  stty -echo 2>/dev/null || true
  ans=""; read -r ans || true
  stty echo 2>/dev/null || true
  echo >&2
  printf '%s\n' "$ans"
}

# --------------------------------------------------------------------------
# OS / package manager detection
# --------------------------------------------------------------------------
# Cygwin: a bare ssh login (and cron) has /bin but neither /usr/bin nor
# /usr/local/bin on PATH - cmake 4.x then cannot find its modules, and
# tools installed by `make install` or `pip --user` are not found.  Put them
# there, /usr/bin first.
case "$(uname -s 2>/dev/null)" in
  CYGWIN*|MSYS*|MINGW*)
    for _d in "$HOME/.local/bin" "$HOME/bin" /usr/local/bin; do
      [ -d "$_d" ] && case ":$PATH:" in *":$_d:"*) ;; *) PATH="$PATH:$_d" ;; esac
    done
    case "$PATH" in /usr/bin:*) ;; *) PATH="/usr/bin:$PATH" ;; esac
    unset _d; export PATH ;;
esac

OS=$(uname -s 2>/dev/null || echo unknown)
IS_CYGWIN=0; case "$OS" in CYGWIN*|MSYS*|MINGW*) IS_CYGWIN=1 ;; esac
IS_MACOS=0;  [ "$OS" = Darwin ] && IS_MACOS=1
IS_LINUX=0;  [ "$OS" = Linux ] && IS_LINUX=1

PKG=""
if   [ "$IS_CYGWIN" = 1 ];                     then PKG=cygwin
elif [ "$IS_MACOS" = 1 ] && command -v brew >/dev/null 2>&1; then PKG=brew
elif command -v apt-get >/dev/null 2>&1;       then PKG=apt
elif command -v dnf     >/dev/null 2>&1;       then PKG=dnf
elif command -v yum     >/dev/null 2>&1;       then PKG=yum
elif command -v pacman  >/dev/null 2>&1;       then PKG=pacman
fi

SUDO=""
if [ "$IS_CYGWIN" = 0 ] && [ "$(id -u)" != 0 ] && command -v sudo >/dev/null 2>&1; then
  SUDO=sudo
fi
# tests set MAIL_SETUP_SUDO= (empty) so nothing ever escalates
[ "${MAIL_SETUP_SUDO+set}" = set ] && SUDO="$MAIL_SETUP_SUDO"

cygwin_install() {   # cygwin_install pkg1 pkg2 ...
  setup=""
  for c in "$(command -v setup-x86_64.exe 2>/dev/null || true)" \
           /cygdrive/c/cygwin64/setup-x86_64.exe /cygdrive/c/cygwin/setup-x86_64.exe; do
    [ -n "$c" ] && [ -x "$c" ] && { setup="$c"; break; }
  done
  if [ -z "$setup" ]; then
    warn "can't find setup-x86_64.exe - install these packages by hand: $*"
    return 1
  fi
  pkgs=$(IFS=,; echo "$*")
  log "running: $setup -q -P $pkgs"
  "$setup" -q -P "$pkgs"
}

pkg_install() {   # pkg_install pkg1 pkg2 ...
  [ $# -gt 0 ] || return 0
  case "$PKG" in
    apt)    $SUDO apt-get update -qq || true
            $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    dnf)    $SUDO dnf install -y "$@" ;;
    yum)    $SUDO yum install -y "$@" ;;
    pacman) $SUDO pacman -Sy --noconfirm "$@" ;;
    brew)   brew install "$@" ;;
    cygwin) cygwin_install "$@" ;;
    *) die "no known package manager - install manually: $*" ;;
  esac
}

# a python3 (>= 3.6) that has ssl; empty if none
find_python() {
  for c in python3 python3.13 python3.12 python3.11 python3.10 python3.9 python3.8 python3.7; do
    p=$(command -v "$c" 2>/dev/null) || continue
    "$p" -c 'import sys,ssl;exit(sys.version_info<(3,6))' 2>/dev/null && { echo "$p"; return 0; }
  done
  return 1
}

# where per-user helper programs go: $MAIL_SETUP_BINDIR if set (e.g. ~/.local/bin),
# else ~/bin - nothing is installed in ~/.local unless asked
user_bindir() {
  echo "${MAIL_SETUP_BINDIR:-$HOME/bin}"
}

# cmpi-router's list of TCP ports open to the LAN: its `setup-router.sh fw`
# rebuilds the firewall from this file, so a port opened only at runtime
# (`nft add rule`) closes on the next reload - 143/993/4190 did, Oct 2026.
LAN_PORTS_FILE="${MAIL_SETUP_LAN_PORTS:-/etc/router-setup/lan0-tcp-ports}"

# lan_ports_record PORT COMMENT -> add "PORT  # COMMENT" to that list.
#   0 added, 1 already there, 2 not a cmpi-router box (no list): nothing done
lan_ports_record() {
  [ -f "$LAN_PORTS_FILE" ] || return 2
  grep -Eq "^[[:space:]]*$1([[:space:]]|\$)" "$LAN_PORTS_FILE" && return 1
  printf '%s  # %s\n' "$1" "$2" | ${SUDO:-} tee -a "$LAN_PORTS_FILE" >/dev/null || return 2
  return 0
}

# lan_ports_keep PORT COMMENT -> lan_ports_record, and say what happened
lan_ports_keep() {
  local rc=0
  lan_ports_record "$1" "$2" || rc=$?
  case $rc in
    0) log "firewall    : $1 added to $LAN_PORTS_FILE - kept open across cmpi-router's"
       log "              'setup-router.sh fw' (run it to open $1 now, if it isn't)" ;;
    1) log "firewall    : $1 already in $LAN_PORTS_FILE" ;;
  esac
  return 0
}

# backup FILE [sudo] -> copy FILE to FILE.bak.<stamp> if it exists
backup() {
  [ -e "$1" ] || return 0
  ${2:+$SUDO} cp -p "$1" "$1.bak.$(date +%Y%m%d-%H%M%S)" && log "backed up existing $1"
}

# cidr_check NET -> NET normalised (192.168.1.7/24 -> 192.168.1.0/24), or fail
cidr_check() {
  _py=$(find_python) || return 1
  "$_py" -c 'import ipaddress,sys; print(ipaddress.ip_network(sys.argv[1], strict=False))' "$1" 2>/dev/null
}

# lan_cidr -> this box's first global IPv4 network, e.g. 192.168.1.0/24, or fail
lan_cidr() {
  _a=$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4; exit}')
  [ -n "$_a" ] || return 1
  cidr_check "$_a"
}
