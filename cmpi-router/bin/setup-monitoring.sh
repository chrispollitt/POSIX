#!/usr/bin/env bash
# Monitoring add-ons for cpbee (Debian 13): SNMP client tools, optional lldpd / packet-capture rights, and LibreNMS.
#
#   sudo ./bin/setup-monitoring.sh tools      SNMP client tools (snmpget, snmpwalk). Debian calls the package `snmp`
#                                             (`net-snmp-utils` is the Red Hat / Cygwin name).
#        WITH_LLDPD=1                         + lldpd, restricted to lan0 (never advertises on the building Wi-Fi), admin user may run lldpctl
#        WITH_SNIFF=1                         + tcpdump with file capabilities (cap_net_raw,cap_net_admin) so SNIFF=1 in the multi-hop trace
#                                               script works without a sudo password. Any local user can then capture packets, but nobody gets root.
#   sudo ./bin/setup-monitoring.sh librenms   LibreNMS (nginx + php-fpm + MariaDB) listening on the lan0 address only
#   sudo ./bin/setup-monitoring.sh check      what is running, firewall rule, web UI answer, LibreNMS validate
#
# Options (environment):  LNMS_PORT=8080   web UI port (port 80 on lan0 is the traffic-graph page)
#                         LAN_IP=...       lan0 address (default: read from /etc/dnsmasq.d/lan.conf)
#                         ADMIN_USER=...   user for lldpctl access (default: the user who ran sudo)
#                         ASSUME_YES=1     skip the confirmation question
#                         DRY_RUN=1        print every command and file that would be written; change nothing (works without root)
#
# LibreNMS notes
#  * Needs the internet (apt, git clone, composer): roughly 0.5-1 GB over the metered WAN.
#  * PHP is Debian's own 8.4 (LibreNMS minimum). The upstream docs use a third-party PHP repo for 8.5; this script does not add one.
#  * The web UI is plain HTTP on the lan0 address only. The port is opened to lan0 through /etc/router-setup/lan0-tcp-ports and
#    `setup-router.sh fw`, so later runs of setup-router.sh keep the rule.
#  * No secrets are stored in this script: the database password is generated on cpbee (/opt/librenms/.env, mode 640) and the web admin
#    account is created interactively by `lnms user:add`.
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
LNMS_PORT="${LNMS_PORT:-8080}"
LNMS_DIR=/opt/librenms
DRY_RUN="${DRY_RUN:-0}"
ASSUME_YES="${ASSUME_YES:-0}"
ADMIN_USER="${ADMIN_USER:-${SUDO_USER:-}}"
LAN_PORTS_FILE=/etc/router-setup/lan0-tcp-ports
export DEBIAN_FRONTEND=noninteractive

die(){ echo "ERROR: $*" >&2; exit 1; }
say(){ printf '\n==> %s\n' "$*"; }
case "${1:-}" in
  tools|librenms|check) [[ $DRY_RUN == 1 || $EUID -eq 0 ]] || die "run as root (sudo)" ;;
esac
[[ $LNMS_PORT =~ ^[0-9]+$ ]] && (( LNMS_PORT >= 1 && LNMS_PORT <= 65535 )) || die "bad LNMS_PORT"

BK=${BACKUP_ROOT:-/root}/monitoring-setup-backup-$(date +%Y%m%d-%H%M%S)
bk(){ [[ -e $1 ]] || return 0; mkdir -p "$BK"; cp -a --parents "$1" "$BK" 2>/dev/null || cp --parents "$1" "$BK"; }
run(){ if [[ $DRY_RUN == 1 ]]; then printf '+ %s\n' "$*"; else "$@"; fi; }
# put <path> <mode> [owner:group]   (content on stdin; old file is saved in $BK)
put(){
  local path=$1 mode=$2 own=${3:-root:root} t
  if [[ $DRY_RUN == 1 ]]; then
    printf '+ write %s (mode %s, %s):\n' "$path" "$mode" "$own"; sed 's/^/    | /'; return 0
  fi
  bk "$path"; install -d "$(dirname "$path")"
  t=$(mktemp "$path.XXXXXX"); cat > "$t"; chmod "$mode" "$t"; chown "$own" "$t"; mv "$t" "$path"
}
apt_install(){ run apt-get install -y "$@"; }
have(){ command -v "$1" >/dev/null 2>&1; }

lan_ip(){
  local ip="${LAN_IP:-}"
  [[ -n $ip ]] || ip=$(sed -n 's/^dhcp-option=option:router,//p' /etc/dnsmasq.d/lan.conf 2>/dev/null | head -1 || true)
  [[ -n $ip ]] || ip=$(ip -4 -o addr show dev lan0 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4; exit}' || true)
  if [[ -z $ip && $DRY_RUN == 1 ]]; then ip=192.168.10.1; echo "(dry run: no lan0 found, using placeholder $ip)" >&2; fi
  [[ -n $ip ]] || die "cannot find the lan0 address (set LAN_IP=...)"
  echo "$ip"
}
confirm(){
  [[ $ASSUME_YES == 1 || $DRY_RUN == 1 ]] && return 0
  local a; read -rp "$1 [y/N] " a; [[ $a == y || $a == Y ]] || die "aborted"
}

# ------------------------------------------------------------------ tools
mode_tools(){
  say "SNMP client tools"
  run apt-get update
  apt_install snmp
  if [[ ${WITH_LLDPD:-0} == 1 ]]; then
    say "lldpd (lan0 only)"
    apt_install lldpd
    put /etc/lldpd.d/10-lan0-only.conf 644 <<'EOF'
# Only speak LLDP on the LAN port. The Wi-Fi link to the building (vr180) and the WAN must not hear about this box.
configure system interface pattern lan0
EOF
    run systemctl enable lldpd
    run systemctl restart lldpd
    if [[ -n $ADMIN_USER ]]; then run adduser "$ADMIN_USER" _lldpd; else echo "(no ADMIN_USER: add yourself with: adduser <user> _lldpd)"; fi
  fi
  if [[ ${WITH_SNIFF:-0} == 1 ]]; then
    say "tcpdump with file capabilities (for SNIFF=1)"
    apt_install tcpdump libcap2-bin
    local tb; tb=$(readlink -f "$(command -v tcpdump 2>/dev/null || echo /usr/bin/tcpdump)")
    run setcap cap_net_raw,cap_net_admin=eip "$tb"
    # a tcpdump upgrade replaces the file and drops the capabilities, so re-apply after every dpkg run
    put /etc/apt/apt.conf.d/99-tcpdump-caps 644 <<EOF
DPkg::Post-Invoke { "if [ -x $tb ]; then setcap cap_net_raw,cap_net_admin=eip $tb || true; fi"; };
EOF
    [[ $DRY_RUN == 1 ]] || getcap "$tb"
  fi
  echo
  echo "Done. Try:  snmpget -v2c -c <community> <host> .1.3.6.1.2.1.1.5.0"
}

# ------------------------------------------------------------------ librenms
mode_librenms(){
  local LAN_IP_ADDR PHPV TZN DBPASS SQLPASS
  LAN_IP_ADDR=$(lan_ip)
  [[ -r /etc/os-release ]] && . /etc/os-release
  [[ ${VERSION_ID:-} == 13 ]] || echo "WARNING: this script targets Debian 13 (found ${PRETTY_NAME:-unknown})"

  # port must be free (or already ours)
  if have ss && ss -ltnHp 2>/dev/null | awk '{print $4, $NF}' | grep -E "[:.]$LNMS_PORT " | grep -qv nginx; then
    die "port $LNMS_PORT is already in use by something other than nginx (set LNMS_PORT=...)"
  fi
  local free_gb; free_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
  (( free_gb >= 5 )) || die "only ${free_gb} GB free on / (need about 5)"

  echo "LibreNMS will be installed in $LNMS_DIR and served at http://$LAN_IP_ADDR:$LNMS_PORT/ (lan0 only)."
  echo "It downloads roughly 0.5-1 GB over the current WAN link (apt, git clone, composer)."
  confirm "Continue?"

  say "packages (nginx is held back while installing so it cannot grab port 80 from the traffic-graph page)"
  if [[ $DRY_RUN == 1 ]]; then echo "+ create /usr/sbin/policy-rc.d denying nginx start; removed again on exit"
  else
    printf '#!/bin/sh\n[ "$1" = nginx ] && exit 101\nexit 0\n' > /usr/sbin/policy-rc.d; chmod 755 /usr/sbin/policy-rc.d
    trap 'rm -f /usr/sbin/policy-rc.d' EXIT
  fi
  run apt-get update
  apt_install acl cron curl fping git mariadb-client mariadb-server mtr-tiny nginx-full nmap \
    php-cli php-curl php-fpm php-gd php-gmp php-mbstring php-mysql php-snmp php-xml php-zip \
    python3-command-runner python3-dotenv python3-pip python3-psutil python3-pymysql python3-redis python3-setuptools python3-systemd \
    rrdtool snmp snmpd traceroute unzip whois openssl

  if [[ $DRY_RUN == 1 ]]; then PHPV=8.4; else PHPV=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;'); fi
  [[ $(printf '%s\n8.4\n' "$PHPV" | sort -V | head -1) == 8.4 ]] || die "PHP $PHPV is older than the LibreNMS minimum 8.4"
  echo "PHP $PHPV"

  say "librenms user and code"
  if id librenms >/dev/null 2>&1; then echo "user librenms exists"; else run useradd librenms -d "$LNMS_DIR" -M -r -s /bin/bash; fi
  if [[ -d $LNMS_DIR/.git ]]; then echo "$LNMS_DIR already cloned: leaving it as is"
  else run git clone https://github.com/librenms/librenms.git "$LNMS_DIR"; fi
  run chown -R librenms:librenms "$LNMS_DIR"
  run chmod 771 "$LNMS_DIR"
  run setfacl -d -m g::rwx "$LNMS_DIR/rrd" "$LNMS_DIR/logs" "$LNMS_DIR/bootstrap/cache/" "$LNMS_DIR/storage/"
  run setfacl -R -m g::rwx "$LNMS_DIR/rrd" "$LNMS_DIR/logs" "$LNMS_DIR/bootstrap/cache/" "$LNMS_DIR/storage/"

  say "PHP dependencies (composer)"
  run runuser -u librenms -- bash -c "cd $LNMS_DIR && ./scripts/composer_wrapper.php install --no-dev"

  say "PHP timezone (the system timezone is not changed)"
  TZN=$(timedatectl show -p Timezone --value 2>/dev/null || true); TZN=${TZN:-Etc/UTC}
  for sapi in fpm cli; do
    put "/etc/php/$PHPV/$sapi/conf.d/99-librenms.ini" 644 <<EOF
date.timezone = $TZN
EOF
  done

  say "MariaDB"
  put /etc/mysql/mariadb.conf.d/60-librenms.cnf 644 <<'EOF'
[mariadbd]
innodb_file_per_table=1
lower_case_table_names=0
EOF
  run systemctl enable mariadb
  run systemctl restart mariadb
  # keep an existing password (re-runs), otherwise generate one; it never appears in a command line
  DBPASS=""
  [[ -r $LNMS_DIR/.env ]] && DBPASS=$(sed -n 's/^DB_PASSWORD=//p' "$LNMS_DIR/.env" | head -1)
  [[ -n $DBPASS ]] || DBPASS=$(openssl rand -hex 16)
  SQLPASS=$DBPASS; [[ $DRY_RUN == 1 ]] && SQLPASS='<generated>'
  if [[ $DRY_RUN == 1 ]]; then
    echo "+ mariadb (as root, over the socket) <<SQL"
    sed 's/^/    | /' <<SQL
CREATE DATABASE IF NOT EXISTS librenms CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'librenms'@'localhost' IDENTIFIED BY '$SQLPASS';
ALTER USER 'librenms'@'localhost' IDENTIFIED BY '$SQLPASS';
GRANT ALL PRIVILEGES ON librenms.* TO 'librenms'@'localhost';
FLUSH PRIVILEGES;
SQL
  else
    mariadb <<SQL
CREATE DATABASE IF NOT EXISTS librenms CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'librenms'@'localhost' IDENTIFIED BY '$SQLPASS';
ALTER USER 'librenms'@'localhost' IDENTIFIED BY '$SQLPASS';
GRANT ALL PRIVILEGES ON librenms.* TO 'librenms'@'localhost';
FLUSH PRIVILEGES;
SQL
  fi

  say "LibreNMS configuration and database"
  if [[ -e $LNMS_DIR/.env ]] && grep -q '^DB_PASSWORD=.' "$LNMS_DIR/.env"; then
    echo ".env already has database settings: keeping it"
  else
    local envout
    envout=$(printf 'DB_HOST=localhost\nDB_DATABASE=librenms\nDB_USERNAME=librenms\nDB_PASSWORD=%s\nAPP_KEY=\n' "$([[ $DRY_RUN == 1 ]] && echo '<generated>' || echo "$DBPASS")")
    printf '%s\n' "$envout" | put "$LNMS_DIR/.env" 640 librenms:librenms
  fi
  if [[ $DRY_RUN == 1 ]] || ! grep -q '^APP_KEY=.\+' "$LNMS_DIR/.env"; then
    run runuser -u librenms -- bash -c "cd $LNMS_DIR && php lnms key:generate --force"
  fi
  run runuser -u librenms -- bash -c "cd $LNMS_DIR && php lnms migrate --seed --force"

  say "PHP-FPM pool"
  local pooldir=/etc/php/$PHPV/fpm/pool.d
  if [[ $DRY_RUN == 1 || ! -e $pooldir/librenms.conf ]]; then
    run cp "$pooldir/www.conf" "$pooldir/librenms.conf"
    run sed -i -e 's/^\[www\]/[librenms]/' -e 's/^user = .*/user = librenms/' -e 's/^group = .*/group = librenms/' \
      -e 's#^listen = .*#listen = /run/php-fpm-librenms.sock#' "$pooldir/librenms.conf"
  else echo "$pooldir/librenms.conf exists: keeping it"; fi
  # the default www pool stays: on cpbee it serves the Apache site (setup-services.sh web); librenms has its own pool and socket

  say "nginx (listens on $LAN_IP_ADDR:$LNMS_PORT only)"
  # https when `setup-services.sh tls` has installed the shared TLS snippet (so a re-run of this step does not undo it)
  tls_listen=""; tls_inc="# plain http (run setup-services.sh tls for https)"
  if [[ -r /etc/nginx/snippets/cpbee-tls.conf ]]; then tls_listen=" ssl"; tls_inc="include snippets/cpbee-tls.conf; error_page 497 =301 https://\$host:\$server_port\$request_uri;"; fi
  sed -e "s|@LISTEN@|$LAN_IP_ADDR:$LNMS_PORT$tls_listen|" -e "s|@TLSINC@|$tls_inc|" <<'EOF' | put /etc/nginx/conf.d/librenms.conf 644
server {
 listen      @LISTEN@;
 @TLSINC@
 server_name _;
 server_tokens off;
 root        /opt/librenms/html;
 index       index.php;

 charset utf-8;
 gzip on;
 gzip_types text/css application/javascript text/javascript application/x-javascript image/svg+xml text/plain text/xsd text/xsl text/xml image/x-icon;
 location / {
  try_files $uri $uri/ /index.php?$query_string;
 }
 location ~ [^/]\.php(/|$) {
  fastcgi_pass unix:/run/php-fpm-librenms.sock;
  fastcgi_split_path_info ^(.+\.php)(/.+)$;
  include fastcgi.conf;
 }
 location ~ /\.(?!well-known).* {
  deny all;
 }
}
EOF
  # the stock site listens on *:80 and would collide with the traffic-graph page
  run rm -f /etc/nginx/sites-enabled/default
  # retry if lan0 is not up yet at boot
  put /etc/systemd/system/nginx.service.d/lan0.conf 644 <<'EOF'
[Unit]
After=systemd-networkd.service
[Service]
Restart=on-failure
RestartSec=10
EOF
  run systemctl daemon-reload
  [[ $DRY_RUN == 1 ]] || rm -f /usr/sbin/policy-rc.d
  run nginx -t
  run systemctl enable nginx "php$PHPV-fpm" snmpd
  run systemctl restart "php$PHPV-fpm"
  run systemctl restart nginx

  say "lnms command, cron, scheduler, logrotate"
  run ln -sf "$LNMS_DIR/lnms" /usr/bin/lnms
  run install -D -m 644 "$LNMS_DIR/misc/lnms-completion.bash" /etc/bash_completion.d/lnms-completion.bash
  run cp "$LNMS_DIR/dist/librenms.cron" /etc/cron.d/librenms
  run cp "$LNMS_DIR/dist/librenms-scheduler.service" "$LNMS_DIR/dist/librenms-scheduler.timer" /etc/systemd/system/
  run systemctl daemon-reload
  run systemctl enable --now librenms-scheduler.timer
  run cp "$LNMS_DIR/misc/librenms.logrotate" /etc/logrotate.d/librenms

  say "firewall: open $LNMS_PORT to lan0 only"
  if [[ $DRY_RUN == 1 ]]; then echo "+ add '$LNMS_PORT  # LibreNMS web UI' to $LAN_PORTS_FILE"
  else
    install -d /etc/router-setup; touch "$LAN_PORTS_FILE"
    grep -Eq "^[[:space:]]*$LNMS_PORT([[:space:]]|$)" "$LAN_PORTS_FILE" || printf '%s  # LibreNMS web UI\n' "$LNMS_PORT" >> "$LAN_PORTS_FILE"
  fi
  if [[ -x $SCRIPT_DIR/setup-router.sh ]] || [[ $DRY_RUN == 1 ]]; then
    run "$SCRIPT_DIR/setup-router.sh" fw
  else
    echo "WARNING: setup-router.sh not found next to this script; open the port by hand:"
    echo "  nft add rule inet filter input iifname lan0 tcp dport $LNMS_PORT accept   (not persistent)"
  fi

  say "first admin user"
  local nusers="0"
  [[ $DRY_RUN == 1 ]] || nusers=$(mariadb -N -B librenms -e 'SELECT COUNT(*) FROM users' 2>/dev/null || echo 0)
  if [[ $nusers == 0 ]]; then
    if [[ $ASSUME_YES == 1 ]] || [[ ! -t 0 && $DRY_RUN != 1 ]]; then
      echo "No web user yet. Create one with:  cd /opt/librenms && sudo -u librenms lnms user:add"
    else
      run runuser -u librenms -- bash -c "cd $LNMS_DIR && php lnms user:add"
    fi
  else echo "$nusers web user(s) already exist"; fi

  say "validate (warnings about HTTPS or updates are expected)"
  run runuser -u librenms -- bash -c "cd $LNMS_DIR && ./validate.php" || true

  cat <<EOF

LibreNMS: http://$LAN_IP_ADDR:$LNMS_PORT/   (from a LAN machine; not reachable from vr180 or the WAN)
Next: add devices in the web UI or with  cd /opt/librenms && sudo -u librenms lnms device:add <host> --v2c -c <community>  (run lnms from /opt/librenms: the librenms user cannot enter your home directory)
      - building-side devices (mesh 192.168.123.101, the vr180 AP 192.168.123.1) are polled over vr180 and need no extra firewall rule
      - set the default community under Settings, or:  cd /opt/librenms && sudo -u librenms lnms config:set snmp.community.0 <community>
Plain HTTP on a private LAN only; do not expose it to the WAN.  Re-check any time with:  sudo ./bin/setup-monitoring.sh check
EOF
}

# ------------------------------------------------------------------ check
mode_check(){
  local ip code
  ok(){ printf '  [ ok ] %s\n' "$*"; }; bad(){ printf '  [FAIL] %s\n' "$*"; }
  ip=$(lan_ip)
  for u in mariadb nginx snmpd librenms-scheduler.timer; do
    systemctl is-active --quiet "$u" && ok "$u active" || bad "$u not active"
  done
  systemctl list-units --type=service --no-legend 'php*-fpm.service' | grep -q running && ok "php-fpm running" || bad "php-fpm not running"
  have snmpget && ok "snmpget installed ($(command -v snmpget))" || echo "  [info] snmp client tools not installed (run: tools)"
  code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://$ip:$LNMS_PORT/login" 2>/dev/null || true)
  [[ $code == 200 ]] && ok "web UI answers 200 at http://$ip:$LNMS_PORT/login" || bad "web UI returned '${code:-none}' at http://$ip:$LNMS_PORT/login"
  local nftr; nftr=$(nft list ruleset 2>/dev/null || true)   # not `nft | grep -q`: with pipefail the early grep exit makes nft fail
  grep -q "iifname \"lan0\" tcp dport $LNMS_PORT accept" <<<"$nftr" && ok "firewall: $LNMS_PORT open to lan0" || bad "firewall rule for $LNMS_PORT missing (run: setup-router.sh fw)"
  grep -Eq "iifname \"(vr180|wan0)\".*dport $LNMS_PORT" <<<"$nftr" && bad "port $LNMS_PORT is open on vr180/wan0!" || ok "port $LNMS_PORT not open on vr180/wan0"
  [[ -d $LNMS_DIR/.git ]] && echo "  [info] LibreNMS $(git -C "$LNMS_DIR" describe --tags 2>/dev/null || echo '(version unknown)') in $LNMS_DIR"
  if have lldpctl; then echo "  [info] lldpd: $(lldpctl -f keyvalue 2>/dev/null | grep -c '\.chassis\.name=' || true) neighbour(s)"; fi
  [[ -d $LNMS_DIR ]] && runuser -u librenms -- bash -c "cd $LNMS_DIR && ./validate.php" 2>&1 | tail -25 || true
}

case "${1:-help}" in
  tools)    mode_tools ;;
  librenms) mode_librenms ;;
  check)    mode_check ;;
  *)        awk 'NR > 1 && /^#/ {print; next} NR > 1 {exit}' "$0"; exit 0 ;;
esac
