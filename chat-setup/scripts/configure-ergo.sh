#!/usr/bin/env bash
#
# configure-ergo.sh
#
# Run an Ergo IRC server (https://ergo.chat) on this box for the LAN: a place
# to test an IRC client (tvmail's chat) without bothering a public network,
# and the start of self-hosted chat.  Ergo is one Go binary with NickServ
# built in, SASL, and the IRCv3 extensions (server-time, echo-message,
# chathistory, labeled-response ...) a modern client expects.
#
# Linux only (systemd).  Debian's package named "ergo" is an unrelated
# quantum-chemistry program, so the server comes from Ergo's own GitHub
# release instead.  The script:
#
#   1. downloads the release for this CPU, checks its SHA-256 (pinned here
#      for the default version, and against the release's checksums.txt) and
#      unpacks it to /opt/ergo/ergo-VERSION-ARCH, with /opt/ergo/current
#      pointing at it.  Already installed: nothing is downloaded;
#   2. creates the 'ergo' system user; its data (accounts, channel
#      registrations) lives in /var/lib/ergo/ircd.db;
#   3. TLS: this host's certificate from the local CA when there is one
#      (/etc/ssl/Simple_Inc/certs/HOST.crt + .key + HOST-chain.pem, as
#      cmpi-router's setup-services.sh leaves them), else a self-signed one
#      made once.  Installed as /etc/ergo/tls/fullchain.pem + privkey.pem
#      (root:ergo 0640), and ca.pem - what a client needs to verify it,
#      also as /opt/ergo/ca.pem (world-readable: /etc/ergo/tls is not);
#   4. writes /etc/ergo/ircd.yaml from that release's own default.yaml,
#      changing only: network and server name, the TLS listener (the LAN
#      address only, port 6697), the certificate paths, the MOTD and the
#      languages directory.  Plaintext stays on loopback (127.0.0.1:6667) as
#      in Ergo's default.  Every change must match exactly once, or the
#      script stops rather than guess at a changed default.yaml.  A previous
#      ircd.yaml is backed up first (local edits are overwritten - re-run
#      with the options instead);
#   5. installs /etc/systemd/system/ergo.service, creates the database on
#      the first run, and (re)starts Ergo.  If it does not come up listening,
#      the previous ircd.yaml is put back and the journal is shown;
#   6. firewall: on a cmpi-router box (/etc/router-setup/lan0-tcp-ports
#      exists) the port is added to that list and `setup-router.sh fw`
#      reloads the ruleset, so it survives a reload; elsewhere, if an
#      nftables input chain drops by default, the rule to add is printed.
#      Only with --open-firewall - by default it just says what is needed;
#   7. --register NICK: creates that NickServ account (password asked for,
#      or $CHAT_SETUP_PASS), over loopback - use it for SASL;
#   8. prints what a client needs: ca.pem and a tvchat.conf section.
#
# Re-runnable.  Never listens on the WAN: the TLS listener is bound to one
# LAN address.
#
# Usage:
#   sudo ./configure-ergo.sh [options]
#
# Options:
#   --version VER       Ergo release (default: 2.19.1)
#   --listen ADDR       address for the TLS listener (default: lan0's IPv4,
#                       else this box's first global IPv4)
#   --port N            TLS port (default: 6697)
#   --server-name NAME  the server's name, with a dot (default: the full
#                       hostname, else the short one + .lan)
#   --network NAME      the network's name (default: LAN)
#   --cert FILE --key FILE [--chain FILE]
#                       use this certificate (+ CA chain, also given to
#                       clients as ca.pem) instead of looking for one
#   --register NICK     create a NickServ account (repeatable)
#   --open-firewall     open the port as described in 6. above
#   --remove            stop and remove the service and /opt/ergo; keeps
#                       /etc/ergo and /var/lib/ergo (accounts) for next time
#   --firewall-plan     just print what step 6 would do, and exit - no root,
#                       nothing changed.  Reads `nft list ruleset` (or the
#                       file in $CHAT_SETUP_NFT_RULESET)
#   --print-config FILE just print the ircd.yaml made from default.yaml FILE
#                       (with the options above) - no root, nothing changed
#   --print-unit        just print the systemd unit
#   --print-download    just print the release URL and its pinned SHA-256
#   -h | --help         show this header
#
set -euo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# the shared helpers (log/warn/die/ask, OS + SUDO detection) are mail-setup's
. "$here/../../mail-setup/lib/common.sh"
# tests set CHAT_SETUP_SUDO= (empty) so nothing ever escalates
[ "${CHAT_SETUP_SUDO+set}" = set ] && SUDO="$CHAT_SETUP_SUDO"

VERSION=2.19.1
LISTEN=""
PORT=6697
SERVER_NAME=""
NETWORK=LAN
CERT=""; KEY=""; CHAIN=""
REGISTER=()
OPEN_FW=0
REMOVE=0
MODE=install       # install | firewall-plan | print-config | print-unit | print-download
PRINT_FROM=""

while [ $# -gt 0 ]; do
  case "$1" in
    --version)      VERSION="${2:?}"; shift 2 ;;
    --listen)       LISTEN="${2:?}"; shift 2 ;;
    --port)         PORT="${2:?}"; shift 2 ;;
    --server-name)  SERVER_NAME="${2:?}"; shift 2 ;;
    --network)      NETWORK="${2:?}"; shift 2 ;;
    --cert)         CERT="${2:?}"; shift 2 ;;
    --key)          KEY="${2:?}"; shift 2 ;;
    --chain)        CHAIN="${2:?}"; shift 2 ;;
    --register)     REGISTER+=("${2:?}"); shift 2 ;;
    --open-firewall) OPEN_FW=1; shift ;;
    --remove)       REMOVE=1; shift ;;
    --firewall-plan) MODE=firewall-plan; shift ;;
    --print-config) MODE=print-config; PRINT_FROM="${2:?}"; shift 2 ;;
    --print-unit)   MODE=print-unit; shift ;;
    --print-download) MODE=print-download; shift ;;
    -h|--help)      usage "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$PORT" in ''|*[!0-9]*) die "--port must be a number" ;; esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "--port must be 1-65535"
case "$VERSION" in ''|*[!0-9.]*) die "--version must look like 2.19.1" ;; esac
# names end up in YAML and in an nft command line: keep them plain
case "$NETWORK$SERVER_NAME" in *[!A-Za-z0-9_.-]*) die "--network / --server-name: letters, digits, . _ - only" ;; esac
for n in "${REGISTER[@]+"${REGISTER[@]}"}"; do
  case "$n" in ''|-*|*[!A-Za-z0-9_\`^{}\|\[\]\\-]*) die "--register: '$n' is not a valid nickname" ;; esac
done
if [ -n "$CERT$KEY" ] && { [ -z "$CERT" ] || [ -z "$KEY" ]; }; then
  die "--cert and --key go together"
fi

PREFIX=/opt/ergo
CONF_DIR=/etc/ergo
CONF="$CONF_DIR/ircd.yaml"
TLS_DIR="$CONF_DIR/tls"
DATA=/var/lib/ergo
UNIT=/etc/systemd/system/ergo.service
LAN_PORTS_FILE="${CHAT_SETUP_LAN_PORTS:-/etc/router-setup/lan0-tcp-ports}"
LOCAL_CA_DIR="${CHAT_SETUP_LOCAL_CA_DIR:-/etc/ssl/Simple_Inc/certs}"
# Ergo wants a dot in a server name (so it cannot be taken for a nick):
# the full hostname if it has one, else the short one + .lan
if [ -z "$SERVER_NAME" ]; then
  SERVER_NAME=$(hostname -f 2>/dev/null || true)
  case "$SERVER_NAME" in
    *.*) ;;
    *) SERVER_NAME="$(hostname -s 2>/dev/null || hostname).lan" ;;
  esac
fi
case "$SERVER_NAME" in
  *.*) ;;
  *) die "--server-name must hold a dot, e.g. $SERVER_NAME.lan (Ergo's rule)" ;;
esac

# --------------------------------------------------------------------------
# the release
# --------------------------------------------------------------------------
release_arch() {   # this CPU as Ergo's release names it
  case "${CHAT_SETUP_ARCH:-$(uname -m)}" in
    x86_64|amd64)   echo linux-x86_64 ;;
    aarch64|arm64)  echo linux-arm64 ;;
    armv6l|armv7l)  echo linux-armv6 ;;
    riscv64)        echo linux-riscv64 ;;
    *) return 1 ;;
  esac
}

pinned_sha() {   # pinned_sha VERSION ARCH -> the SHA-256 checked into this script, or fail
  case "$1 $2" in
    "2.19.1 linux-x86_64")  echo c275f2de8e8eb074c38707136392290172400b5b78616cb9f660351527924b47 ;;
    "2.19.1 linux-arm64")   echo 3f68fee0ede09eeeb205a553fe9727b409c686752e1cc2fea34ae2f9d64517fb ;;
    "2.19.1 linux-armv6")   echo eeef7f7a2174b43f237949dbc96c13042b9293b2a60fe0851d37e8bcea4f50cb ;;
    "2.19.1 linux-riscv64") echo ff64b8c4da3b5e793d24436757546e9689b07aa29f3dbe7e4b07fb5006c71c1a ;;
    *) return 1 ;;
  esac
}

ARCH=$(release_arch) || ARCH=""
TARBALL="ergo-$VERSION-$ARCH.tar.gz"
BASE_URL="https://github.com/ergochat/ergo/releases/download/v$VERSION"

# --------------------------------------------------------------------------
# where to listen
# --------------------------------------------------------------------------
default_listen() {
  ip -4 -o addr show dev lan0 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4; exit}' | grep . \
    || ip -4 -o addr show scope global 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4; exit}'
}
iface_of() {   # iface_of ADDR -> the interface that holds it
  [ -n "${CHAT_SETUP_IFACE:-}" ] && { echo "$CHAT_SETUP_IFACE"; return 0; }
  ip -4 -o addr show 2>/dev/null | awk -v a="$1" '{split($4, p, "/"); if (p[1] == a) {print $2; exit}}'
}
if [ -z "$LISTEN" ] && [ "$MODE" != print-unit ] && [ "$MODE" != print-download ]; then
  LISTEN=$(default_listen || true)
  [ -n "$LISTEN" ] || LISTEN=${CHAT_SETUP_DEFAULT_LISTEN:-}
  [ -n "$LISTEN" ] || die "no LAN address found - give one with --listen"
fi
case "$LISTEN" in *[!0-9.]*) die "--listen must be an IPv4 address (one LAN address, never 0.0.0.0)" ;; esac
[ "$LISTEN" != 0.0.0.0 ] || die "--listen 0.0.0.0 would serve the WAN too - give the LAN address"

# --------------------------------------------------------------------------
# ircd.yaml from the release's default.yaml.  Python, not sed: each change is
# an exact block of the default that must occur once - a default.yaml that
# has moved on makes this fail loudly instead of writing half a config.
# --------------------------------------------------------------------------
make_config() {   # make_config DEFAULT_YAML -> ircd.yaml on stdout
  local py; py=$(find_python) || die "python3 is needed to write ircd.yaml"
  "$py" - "$1" "$NETWORK" "$SERVER_NAME" "$LISTEN:$PORT" "$TLS_DIR" "$CONF_DIR" "$PREFIX/current" "$VERSION" <<'PYEOF'
import io, sys
src, network, server, listen, tls, conf, cur, ver = sys.argv[1:]
s = io.open(src, encoding="utf-8").read()
edits = [
    ("network:\n    # name of the network\n    name: ErgoTest\n",
     "network:\n    # name of the network\n    name: %s\n" % network),
    ("server:\n    # server name\n    name: ergo.test\n",
     "server:\n    # server name\n    name: %s\n" % server),
    ('        ":6697":\n',
     '        # (chat-setup: the LAN address only - never every interface)\n'
     '        "%s":\n' % listen),
    ("            tls:\n                cert: fullchain.pem\n                key: privkey.pem\n",
     "            tls:\n                cert: %s/fullchain.pem\n                key: %s/privkey.pem\n"
     % (tls, tls)),
    ("    motd: ergo.motd\n", "    motd: %s/ergo.motd\n" % conf),
    ("    # which directory contains our language files\n    path: languages\n",
     "    # which directory contains our language files\n    path: %s/languages\n" % cur),
]
for old, new in edits:
    n = s.count(old)
    if n != 1:
        sys.exit("configure-ergo: default.yaml changed - expected exactly one %r, found %d"
                 % (old.strip().splitlines()[-1], n))
    s = s.replace(old, new)
head = ("# ircd.yaml - written by chat-setup/scripts/configure-ergo.sh from Ergo %s's\n"
        "# default.yaml.  Re-running the script rewrites it (the old one is backed up):\n"
        "# change the script's options rather than editing this file.\n\n" % ver)
sys.stdout.write(head + s)
PYEOF
}

make_unit() {
  cat <<EOF
# ergo.service - written by chat-setup/scripts/configure-ergo.sh
[Unit]
Description=Ergo IRC server
Documentation=https://ergo.chat/
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
NotifyAccess=main
User=ergo
Group=ergo
WorkingDirectory=$DATA
ExecStart=$PREFIX/current/ergo run --conf $CONF
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=$DATA

[Install]
WantedBy=multi-user.target
EOF
}

# --------------------------------------------------------------------------
# firewall: what step 6 would do, as "how<TAB>what" lines:
#   ports-file  FILE         add PORT to cmpi-router's list (then setup-router.sh fw)
#   nft         COMMAND      a runtime rule
#   note        TEXT         nothing can be done automatically
# Nothing printed: the port is already open (or nothing filters it).
# --------------------------------------------------------------------------
fw_ruleset() {
  if [ -n "${CHAT_SETUP_NFT_RULESET:-}" ]; then cat "$CHAT_SETUP_NFT_RULESET" 2>/dev/null || true
  elif command -v nft >/dev/null 2>&1; then ${SUDO:-} nft list ruleset 2>/dev/null || true
  fi
}
fw_plan() {
  local iif; iif=$(iface_of "$LISTEN")
  if [ -f "$LAN_PORTS_FILE" ]; then
    grep -Eq "^[[:space:]]*$PORT([[:space:]]|\$)" "$LAN_PORTS_FILE" \
      || printf 'ports-file\t%s\n' "$LAN_PORTS_FILE"
    return 0
  fi
  # input chains that drop by default and accept nothing on PORT
  fw_ruleset | awk -v port="$PORT" '
    function has(line, p) { return (" " line " ") ~ ("[^0-9]" p "[^0-9]") }
    /^table / { fam = $2; tbl = $3; chain = ""; next }
    /^[ \t]*chain / { chain = $2; hook = 0; drop = 0; ok = 0; next }
    chain != "" && /type filter hook input/ { hook = 1; drop = ($0 ~ /policy drop/); next }
    chain != "" && hook && /dport/ && /accept/ && has($0, port) { ok = 1; next }
    /^[ \t]*}/ && chain != "" {
      if (hook && drop && !ok) printf "%s\t%s\t%s\n", fam, tbl, chain
      chain = ""
    }' | while IFS=$'\t' read -r fam tbl chain; do
      case "$fam$tbl$chain$iif" in *[!A-Za-z0-9_.@:-]*) continue ;; esac
      if [ -n "$iif" ]; then
        printf 'nft\tnft add rule %s %s %s iifname "%s" tcp dport %s accept\n' "$fam" "$tbl" "$chain" "$iif" "$PORT"
      else
        printf 'note\tnftables %s %s %s drops %s by default and no interface holds %s\n' \
          "$fam" "$tbl" "$chain" "$PORT" "$LISTEN"
      fi
    done
}

router_script() {   # cmpi-router's setup-router.sh, if it can be found
  local u h
  [ -n "${CHAT_SETUP_ROUTER:-}" ] && { echo "$CHAT_SETUP_ROUTER"; return 0; }
  for u in "${SUDO_USER:-}" "$(id -un)"; do
    [ -n "$u" ] || continue
    h=$(getent passwd "$u" | cut -d: -f6)
    [ -x "$h/cmpi-router/bin/setup-router.sh" ] && { echo "$h/cmpi-router/bin/setup-router.sh"; return 0; }
  done
  return 1
}

# --------------------------------------------------------------------------
# the print-only modes (no root, nothing changed)
# --------------------------------------------------------------------------
case "$MODE" in
  print-config)   make_config "$PRINT_FROM"; exit 0 ;;
  print-unit)     make_unit; exit 0 ;;
  print-download)
    [ -n "$ARCH" ] || die "no Ergo release for this CPU ($(uname -m))"
    printf '%s/%s\n' "$BASE_URL" "$TARBALL"
    pinned_sha "$VERSION" "$ARCH" || echo "(no pinned SHA-256 for $VERSION $ARCH: checked against the release's checksums.txt only)"
    exit 0 ;;
  firewall-plan)
    fw_plan | while IFS=$'\t' read -r how what; do
      case "$how" in
        ports-file) echo "add '$PORT  # Ergo IRC (chat-setup)' to $what, then run setup-router.sh fw" ;;
        nft)        echo "$what" ;;
        note)       echo "NOTE: $what" ;;
      esac
    done
    exit 0 ;;
esac

# --------------------------------------------------------------------------
# from here on: the real thing
# --------------------------------------------------------------------------
[ "$IS_LINUX" = 1 ] || die "Linux only"
if [ "$(id -u)" != 0 ] && [ -z "$SUDO" ]; then die "run as root (no sudo found)"; fi
[ -d /run/systemd/system ] || die "this needs systemd"

if [ "$REMOVE" = 1 ]; then
  step "removing Ergo"
  $SUDO systemctl disable --now ergo 2>/dev/null || true
  $SUDO rm -f "$UNIT"
  $SUDO systemctl daemon-reload
  $SUDO rm -rf "$PREFIX"
  log "removed the service and $PREFIX; kept $CONF_DIR and $DATA (accounts)"
  [ -f "$LAN_PORTS_FILE" ] && grep -Eq "^[[:space:]]*$PORT([[:space:]]|\$)" "$LAN_PORTS_FILE" \
    && log "port $PORT is still listed in $LAN_PORTS_FILE - delete that line and run setup-router.sh fw to close it"
  exit 0
fi

[ -n "$ARCH" ] || die "no Ergo release for this CPU ($(uname -m))"
for c in tar sha256sum systemctl; do command -v "$c" >/dev/null 2>&1 || die "$c is needed"; done
command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || die "curl or wget is needed"
find_python >/dev/null || die "python3 is needed"

step "Ergo $VERSION on $SERVER_NAME ($LISTEN:$PORT)"

# 1. the release -------------------------------------------------------------
fetch() {   # fetch URL FILE
  if command -v curl >/dev/null 2>&1; then curl -fsSL --retry 2 -o "$2" "$1"
  else wget -q -O "$2" "$1"; fi
}
DEST="$PREFIX/ergo-$VERSION-$ARCH"
if [ -x "$DEST/ergo" ] && "$DEST/ergo" --version 2>/dev/null | grep -q -- "$VERSION"; then
  log "ergo        : $VERSION already in $DEST"
else
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  log "downloading $BASE_URL/$TARBALL ..."
  fetch "$BASE_URL/$TARBALL" "$tmp/$TARBALL" || die "download failed: $BASE_URL/$TARBALL"
  fetch "$BASE_URL/ergo-$VERSION-checksums.txt" "$tmp/sums" || die "download failed: the release's checksums.txt"
  got=$(sha256sum "$tmp/$TARBALL" | awk '{print $1}')
  listed=$(awk -v f="$TARBALL" '$2 == f || $2 == "*" f {print $1}' "$tmp/sums")
  [ -n "$listed" ] && [ "$got" = "$listed" ] || die "SHA-256 mismatch against the release's checksums.txt - not installing"
  if pin=$(pinned_sha "$VERSION" "$ARCH"); then
    [ "$got" = "$pin" ] || die "SHA-256 mismatch against the value pinned in this script - not installing"
    log "sha256      : ok (pinned, and the release's checksums.txt)"
  else
    warn "no pinned SHA-256 for $VERSION $ARCH: checked against the release's own checksums.txt only"
  fi
  mkdir -p "$tmp/x"
  tar -xzf "$tmp/$TARBALL" -C "$tmp/x"
  bin=$(find "$tmp/x" -maxdepth 2 -type f -name ergo | head -1)
  [ -n "$bin" ] || die "no ergo binary in $TARBALL"
  $SUDO install -d -m 755 "$PREFIX"
  $SUDO rm -rf "$DEST"
  $SUDO cp -R "$(dirname "$bin")" "$DEST"
  $SUDO chown -R root:root "$DEST"
  log "ergo        : $("$DEST/ergo" --version 2>/dev/null) -> $DEST"
fi
$SUDO ln -sfn "$(basename "$DEST")" "$PREFIX/current"

# 2. the user -----------------------------------------------------------------
if ! getent passwd ergo >/dev/null; then
  if command -v adduser >/dev/null 2>&1 && adduser --help 2>&1 | grep -q -- --system; then
    $SUDO adduser --system --group --home "$DATA" --no-create-home --shell /usr/sbin/nologin ergo >/dev/null
  else
    $SUDO useradd --system --user-group --home-dir "$DATA" --shell /usr/sbin/nologin ergo
  fi
  log "user        : ergo created"
fi
$SUDO install -d -o ergo -g ergo -m 750 "$DATA"
$SUDO install -d -o root -g ergo -m 750 "$CONF_DIR" "$TLS_DIR"

# 3. TLS ---------------------------------------------------------------------
host=$(hostname -s 2>/dev/null || hostname)
if [ -z "$CERT" ] && [ -f "$LOCAL_CA_DIR/$host.crt" ] && $SUDO test -f "$LOCAL_CA_DIR/$host.key"; then
  CERT="$LOCAL_CA_DIR/$host.crt"; KEY="$LOCAL_CA_DIR/$host.key"
  [ -f "$LOCAL_CA_DIR/$host-chain.pem" ] && CHAIN="$LOCAL_CA_DIR/$host-chain.pem"
  log "tls         : the local CA's certificate for $host ($CERT)"
fi
if [ -z "$CERT" ]; then
  command -v openssl >/dev/null 2>&1 || die "openssl is needed to make a certificate (or give --cert/--key)"
  CERT="$TLS_DIR/selfsigned.crt"; KEY="$TLS_DIR/selfsigned.key"
  if ! $SUDO test -f "$KEY"; then
    san="DNS:$host,DNS:$SERVER_NAME,IP:$LISTEN"
    $SUDO openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
      -subj "/CN=$SERVER_NAME" -addext "subjectAltName=$san" \
      -keyout "$KEY" -out "$CERT" 2>/dev/null || die "openssl could not make a certificate"
    log "tls         : made a self-signed certificate for $san (10 years)"
  else
    log "tls         : the self-signed certificate made before ($CERT)"
  fi
fi
install_if_changed() {   # install_if_changed SRC DEST MODE  (root:ergo); 0 = changed
  if $SUDO cmp -s "$1" "$2" 2>/dev/null; then return 1; fi
  $SUDO install -o root -g ergo -m "$3" "$1" "$2"
}
tls_changed=0
t=$(mktemp)
{ $SUDO cat "$CERT"; [ -n "$CHAIN" ] && $SUDO cat "$CHAIN"; } > "$t"
install_if_changed "$t" "$TLS_DIR/fullchain.pem" 644 && tls_changed=1
if [ -n "$CHAIN" ]; then $SUDO cat "$CHAIN" > "$t"; else $SUDO cat "$CERT" > "$t"; fi
install_if_changed "$t" "$TLS_DIR/ca.pem" 644 || true
# $TLS_DIR is root:ergo 0750 (the key), so a client fetches this copy instead
$SUDO install -d -m 755 "$PREFIX"
$SUDO cmp -s "$t" "$PREFIX/ca.pem" 2>/dev/null || $SUDO install -o root -g root -m 644 "$t" "$PREFIX/ca.pem"
rm -f "$t"
install_if_changed "$KEY" "$TLS_DIR/privkey.pem" 640 && tls_changed=1

# 4. ircd.yaml ---------------------------------------------------------------
if ! $SUDO test -f "$CONF_DIR/ergo.motd"; then
  printf '%s\n' "Welcome to $NETWORK on $SERVER_NAME - a LAN IRC server (Ergo $VERSION)." \
    "Accounts: /msg NickServ HELP" | $SUDO tee "$CONF_DIR/ergo.motd" >/dev/null
  $SUDO chown root:ergo "$CONF_DIR/ergo.motd"; $SUDO chmod 640 "$CONF_DIR/ergo.motd"
fi
new=$(mktemp)
make_config "$PREFIX/current/default.yaml" > "$new"
old=""
conf_changed=0
if $SUDO cmp -s "$new" "$CONF"; then
  log "ircd.yaml   : unchanged"
else
  if $SUDO test -f "$CONF"; then
    old="$CONF.bak.$(date +%Y%m%d-%H%M%S)"
    $SUDO cp -p "$CONF" "$old" && log "backed up $CONF -> $old"
  fi
  $SUDO install -o root -g ergo -m 640 "$new" "$CONF"
  conf_changed=1
  log "ircd.yaml   : written ($NETWORK, $SERVER_NAME, TLS on $LISTEN:$PORT, plaintext on 127.0.0.1:6667)"
fi
rm -f "$new"

# 5. service -----------------------------------------------------------------
unit_new=$(mktemp)
make_unit > "$unit_new"
unit_changed=0
if ! cmp -s "$unit_new" "$UNIT" 2>/dev/null; then
  $SUDO install -m 644 "$unit_new" "$UNIT"
  $SUDO systemctl daemon-reload
  unit_changed=1
fi
rm -f "$unit_new"
if ! $SUDO test -f "$DATA/ircd.db"; then
  (cd "$DATA" && $SUDO runuser -u ergo -- "$PREFIX/current/ergo" initdb --conf "$CONF" --quiet) \
    || die "ergo initdb failed"
  log "database    : created $DATA/ircd.db"
fi
listening() {   # listening ADDR:PORT
  ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qx "$1"
}
up() { listening "$LISTEN:$PORT" && listening "127.0.0.1:6667"; }
$SUDO systemctl enable ergo >/dev/null 2>&1
if [ "$conf_changed$unit_changed" != 00 ] || ! systemctl is-active -q ergo; then
  $SUDO systemctl restart ergo || true
elif [ "$tls_changed" = 1 ]; then
  $SUDO systemctl reload ergo && log "service     : reloaded (new certificate)"
fi
for _ in 1 2 3 4 5 6 7 8 9 10; do up && break; sleep 1; done
if ! up; then
  warn "Ergo is not listening on $LISTEN:$PORT and 127.0.0.1:6667 - the last journal lines:"
  $SUDO journalctl -u ergo -n 30 --no-pager >&2 || true
  if [ -n "$old" ]; then
    $SUDO cp -p "$old" "$CONF" && $SUDO systemctl restart ergo || true
    die "put the previous ircd.yaml back ($old)"
  fi
  die "Ergo did not start"
fi
log "service     : ergo running - TLS $LISTEN:$PORT, plaintext 127.0.0.1:6667"

# 6. firewall ----------------------------------------------------------------
FW=$(fw_plan)
if [ -n "$FW" ]; then
  while IFS=$'\t' read -r how what; do
    case "$how" in
      ports-file)
        if [ "$OPEN_FW" = 1 ]; then
          printf '%s  # Ergo IRC (chat-setup)\n' "$PORT" | $SUDO tee -a "$what" >/dev/null
          log "firewall    : added $PORT to $what"
          if sr=$(router_script); then
            $SUDO "$sr" fw && log "firewall    : reloaded ($sr fw)"
          else
            warn "now run 'sudo ./bin/setup-router.sh fw' in cmpi-router to load the rule"
          fi
        else
          warn "the firewall drops $PORT: re-run with --open-firewall (adds it to $what"
          warn "  and reloads with cmpi-router's setup-router.sh fw)"
        fi ;;
      nft)
        if [ "$OPEN_FW" = 1 ]; then
          eval "$SUDO $what" && log "firewall    : $what"     # names vetted in fw_plan
          warn "that rule is lost when nftables reloads - add it to your ruleset file too"
        else
          warn "nftables drops $PORT by default, so clients will time out.  open it now:"
          warn "  $what      (or re-run with --open-firewall)"
        fi ;;
      note) warn "$what" ;;
    esac
  done <<<"$FW"
else
  log "firewall    : nothing to open"
fi

# 7. accounts ----------------------------------------------------------------
for nick in "${REGISTER[@]+"${REGISTER[@]}"}"; do
  pw="${CHAT_SETUP_PASS:-}"
  if [ -z "$pw" ]; then
    pw=$(readsecret "NickServ password for $nick")
    [ "$pw" = "$(readsecret "again")" ] || die "the passwords differ"
  fi
  [ -n "$pw" ] || die "an empty password"
  CHAT_SETUP_PASS="$pw" "$(find_python)" "$here/ergo-register.py" 127.0.0.1 6667 "$nick" \
    || die "could not register $nick"
done

# 8. what a client needs -----------------------------------------------------
fqdn=$(hostname -f 2>/dev/null || echo "$host")
cat <<EOF

== for a client (tvmail's chat) ==
  On the client, chat-setup/scripts/configure-tvchat.sh does all of this:
      ./configure-tvchat.sh --host $host --port $PORT --nick YOURNICK
  By hand: the server's CA, to verify it - copy it to the client machine:
      scp $host:$PREFIX/ca.pem ~/.config/tvmail/$host-ca.pem
  then add to ~/.config/tvmail/tvchat.conf (cafile needs the full path;
  comments go on lines of their own - one after a value becomes part of it):

      [account:$host]
      protocol = irc
      display  = $NETWORK ($host)
      # must match the certificate: $host, or $LISTEN
      host     = $host
      port     = $PORT
      tls      = true
      verify   = true
      cafile   = /home/YOU/.config/tvmail/$host-ca.pem
      nick     = YOURNICK
      # once registered (--register YOURNICK); omit to connect unauthenticated
      sasl     = YOURNICK
      channels = #test

  and the SASL password in ~/.netrc (machine $host login YOURNICK password ...)
  or \$TVCHAT_PASS_$(echo "$host" | tr 'a-z.-' 'A-Z__').
  Server: $fqdn, log: journalctl -u ergo; config: $CONF
EOF
