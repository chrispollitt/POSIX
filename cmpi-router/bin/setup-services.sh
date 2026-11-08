#!/usr/bin/env bash
# Services taken over from the Raspberry Pi (cmpi) on cpbee (Debian 13): Apache + PHP-FPM (the HTTPS site) and Postfix (outbound relay).
#
#   ./bin/setup-services.sh fetch        (NOT root) copy the cert/key and the mail relay login from cmpi over ssh into ~/cmpi-import/secrets (mode 700)
#   sudo ./bin/setup-services.sh web     Apache + PHP-FPM: https on the lan0 address only, docroot copied from ~/cmpi-import/www/html, /mesh/ and /test/ proxy to the mesh server
#   sudo ./bin/setup-services.sh mail    Postfix satellite: relay through [u-l.ca]:465 with the Pi's login, accepts mail from lan0 only
#   sudo ./bin/setup-services.sh check   what is running, what listens where, a test fetch of the site
#   sudo ./bin/setup-services.sh mailtest you@example.com    send one test message through the relay
#   sudo ./bin/setup-services.sh webmin  Webmin (official apt repo; you confirm the key fingerprint), https on lan0:10000, login = your Unix account
#   sudo ./bin/setup-services.sh ftp     vsftpd installed STOPPED and disabled (FTP_WRITE=YES allows uploads); telnet = inetutils-telnetd on a systemd socket, not enabled
#   sudo ./bin/setup-services.sh on|off ftp|telnet   start/stop and open/close its lan0 port in the LIVE firewall (a reboot closes it); `status` shows all
#   sudo ./bin/setup-services.sh cert    swap the https certificate on Apache + Webmin to $CERT_NAME (default cpbee) from ~/cmpi-import/secrets
#   sudo ./bin/setup-services.sh nohsts  stop Apache and Webmin from sending HSTS (sends max-age=0 so browsers forget it; HSTS is per host name, not per port, and breaks http://cpbee:8080)
#   sudo ./bin/setup-services.sh pma-user   create a MariaDB admin login (password asked, hidden) for phpMyAdmin; root@localhost uses unix_socket and cannot log in from the web
#   sudo ./bin/setup-services.sh tls     https for LibreNMS (:8080) and the traffic graphs (nginx TLS front on :8443, :80 redirects); backend python moves to 127.0.0.1:8081
#   sudo ./bin/setup-services.sh servers   install the "servers list" page at https://<name>/servers/ (source: www/servers.html)
#   sudo ./bin/setup-services.sh servers-admin   the logged-in servers page https://<name>/servers/admin/: Apache login + start/stop/restart buttons through a root helper (bin/cpbee-service, www/servers-control.php); asks for the page password
#   sudo ./bin/setup-services.sh webmin-tmp   move Webmin's temp files from the RAM-disk /tmp to /var/tmp/.webmin (silences Webmin's tmpfs notice; `webmin` does it on a fresh install)
#   sudo ./bin/setup-services.sh pma-quiet   hide phpMyAdmin's "Since twig/twig 3.21 ... is deprecated" notices (Debian's newer php-twig vs phpMyAdmin 5.2.2); other errors still show
#
# Options (environment): SRC_HOST=chris@192.168.123.253  cmpi as reachable from cpbee (default: via vr180)
#                        IMPORT=~/cmpi-import             where pull-from-cmpi.sh put the data
#                        LAN_IP=...                       lan0 address (default read from /etc/dnsmasq.d/lan.conf)
#                        SITE_NAME=cpbee                  Apache/Webmin name (the certificate must carry it)  CERT_NAME=cpbee  base name of the cert+key in ~/cmpi-import/secrets
#                        ASSUME_YES=1  DRY_RUN=1          skip questions / print only (works without root)
#
# NOT migrated on purpose: telnet, plain-text FTP, Webmin, Pi-hole/ndpmon, CUPS, ntp (cpbee uses systemd-timesyncd), Dovecot and MariaDB (both disabled on the Pi),
# the 6767 two-factor site (unused cmnet experiment, Python CGI written for 3.7). Its files are in ~/cmpi-import/www/6767 if it is ever wanted.
# Secrets: the certificate key and the relay login live only under ~/cmpi-import/secrets and /etc on cpbee. Never copy them into this folder.
set -euo pipefail

SRC_HOST="${SRC_HOST:-chris@192.168.123.253}"
DRY_RUN="${DRY_RUN:-0}"
ASSUME_YES="${ASSUME_YES:-0}"
SITE_NAME="${SITE_NAME:-cpbee}"
CERT_NAME="${CERT_NAME:-cpbee}"
RUN_USER="${SUDO_USER:-$USER}"
RUN_HOME=$(getent passwd "$RUN_USER" | cut -d: -f6)
IMPORT="${IMPORT:-$RUN_HOME/cmpi-import}"
SECRETS="$IMPORT/secrets"
LAN_PORTS_FILE=/etc/router-setup/lan0-tcp-ports
export DEBIAN_FRONTEND=noninteractive

die(){ echo "ERROR: $*" >&2; exit 1; }
say(){ printf '\n==> %s\n' "$*"; }
case "${1:-}" in
  web|mail|check|mailtest|webmin|ftp|telnet|on|off|status|cert|nohsts|pma-user|tls|servers|servers-admin|webmin-tmp|pma-quiet) [[ $DRY_RUN == 1 || $EUID -eq 0 ]] || die "run as root (sudo)" ;;
  fetch) [[ $EUID -ne 0 ]] || die "run 'fetch' as your normal user (it uses your ssh key to reach cmpi)" ;;
esac

BK=${BACKUP_ROOT:-/root}/services-setup-backup-$(date +%Y%m%d-%H%M%S)
bk(){ [[ -e $1 ]] || return 0; mkdir -p "$BK"; cp -a --parents "$1" "$BK"; }
run(){ if [[ $DRY_RUN == 1 ]]; then printf '+ %s\n' "$*"; else "$@"; fi; }
put(){   # put <path> <mode> [owner:group]  (content on stdin; old file saved in $BK)
  local path=$1 mode=$2 own=${3:-root:root} t
  if [[ $DRY_RUN == 1 ]]; then
    printf '+ write %s (mode %s, %s):\n' "$path" "$mode" "$own"
    if [[ $mode == 600 ]]; then cat >/dev/null; echo '    | (secret, content not shown)'; else sed 's/^/    | /'; fi
    return 0
  fi
  bk "$path"; install -d "$(dirname "$path")"
  t=$(mktemp "$path.XXXXXX"); cat > "$t"; chmod "$mode" "$t"; chown "$own" "$t"; mv "$t" "$path"
}
confirm(){ [[ $ASSUME_YES == 1 || $DRY_RUN == 1 ]] && return 0; local a; read -rp "$1 [y/N] " a; [[ $a == y || $a == Y ]] || die "aborted"; }
lan_ip(){
  local ip="${LAN_IP:-}"
  [[ -n $ip ]] || ip=$(sed -n 's/^dhcp-option=option:router,//p' /etc/dnsmasq.d/lan.conf 2>/dev/null | head -1 || true)
  [[ -n $ip ]] || ip=$(ip -4 -o addr show dev lan0 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4; exit}' || true)
  if [[ -z $ip && $DRY_RUN == 1 ]]; then ip=192.168.10.1; fi
  [[ -n $ip ]] || die "cannot find the lan0 address (set LAN_IP=...)"
  echo "$ip"
}
lan_net(){ local ip=$1; echo "${ip%.*}.0/24"; }
open_port(){   # open_port <port> <comment>  -> /etc/router-setup/lan0-tcp-ports, then reload the firewall
  if [[ $DRY_RUN == 1 ]]; then echo "+ add '$1  # $2' to $LAN_PORTS_FILE and run setup-router.sh fw"; return 0; fi
  install -d /etc/router-setup; touch "$LAN_PORTS_FILE"
  grep -Eq "^[[:space:]]*$1([[:space:]]|$)" "$LAN_PORTS_FILE" || printf '%s  # %s\n' "$1" "$2" >> "$LAN_PORTS_FILE"
  local sr; sr="$(dirname "$(readlink -f "$0")")/setup-router.sh"
  [[ -x $sr ]] && "$sr" fw || echo "NOTE: run 'sudo ./bin/setup-router.sh fw' to load the new firewall rule"
}

# ------------------------------------------------------------------ fetch
mode_fetch(){
  say "pulling certificate, key and relay login from $SRC_HOST"
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$SRC_HOST" true || die "cannot ssh to $SRC_HOST"
  umask 077; mkdir -p "$SECRETS"; chmod 700 "$SECRETS"
  scp -q "$SRC_HOST:/etc/ssl/Simple_Inc/certs/cmpi.crt" "$SRC_HOST:/etc/ssl/Simple_Inc/certs/cmpi.key" "$SECRETS/"
  scp -q "$SRC_HOST:/etc/postfix/sasl_passwd" "$SECRETS/sasl_passwd"
  scp -q "$SRC_HOST:/etc/postfix/generic" "$SRC_HOST:/etc/postfix/lan-canonical" "$SECRETS/"
  chmod 600 "$SECRETS"/*
  ls -l "$SECRETS"
  openssl x509 -in "$SECRETS/cmpi.crt" -noout -subject -enddate
  echo "sasl_passwd has $(wc -l < "$SECRETS/sasl_passwd") line(s), format: $(sed -E 's/^(\S+) [^:]*:.*/\1 <user>:<hidden>/' "$SECRETS/sasl_passwd" | head -1)"
}

# ------------------------------------------------------------------ web
mode_web(){
  local ip; ip=$(lan_ip)
  [[ -r $SECRETS/$CERT_NAME.crt && -r $SECRETS/$CERT_NAME.key ]] || die "missing $SECRETS/$CERT_NAME.{crt,key}: run './bin/setup-services.sh fetch' first"
  [[ -d $IMPORT/www/html ]] || die "missing $IMPORT/www/html: run './bin/pull-from-cmpi.sh web' first"
  openssl x509 -in "$SECRETS/$CERT_NAME.crt" -noout -checkend 0 >/dev/null || die "certificate expired"
  [[ $(openssl x509 -in "$SECRETS/$CERT_NAME.crt" -noout -pubkey | sha256sum) == $(openssl pkey -in "$SECRETS/$CERT_NAME.key" -pubout | sha256sum) ]] || die "certificate and key do not match"
  echo "Apache will serve https://$SITE_NAME/ on $ip:443 (lan0 only) from a copy of the Pi's /var/www/html. Needs the internet (apt)."
  confirm "Continue?"

  say "packages (apache2 is held back while installing so it cannot start on the default ports)"
  if [[ $DRY_RUN == 1 ]]; then echo "+ policy-rc.d denies apache2 start during install"
  else printf '#!/bin/sh\n[ "$1" = apache2 ] && exit 101\nexit 0\n' > /usr/sbin/policy-rc.d; chmod 755 /usr/sbin/policy-rc.d; trap 'rm -f /usr/sbin/policy-rc.d' EXIT; fi
  run apt-get update
  run apt-get install -y apache2 php-fpm php-cli php-curl php-gd php-mbstring php-xml php-zip rsync
  local PHPV; if [[ $DRY_RUN == 1 ]]; then PHPV=8.4; else PHPV=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;'); fi

  say "certificate and key (root only)"
  run install -d -m 755 /etc/ssl/Simple_Inc/certs
  run install -m 644 "$([[ -r $SECRETS/$CERT_NAME.chn ]] && echo "$SECRETS/$CERT_NAME.chn" || echo "$SECRETS/$CERT_NAME.crt")" "/etc/ssl/Simple_Inc/certs/$CERT_NAME.crt"   # leaf first, then the chain, when a .chn bundle exists
  run install -m 600 -o root -g root "$SECRETS/$CERT_NAME.key" /etc/ssl/Simple_Inc/certs/$CERT_NAME.key

  say "site name 'mesh' (the proxy target) in /etc/hosts"
  if [[ $DRY_RUN != 1 ]] && ! grep -Eq '^[0-9.]+[[:space:]]+mesh([[:space:]]|$)' /etc/hosts; then
    bk /etc/hosts; printf '192.168.123.101\tmesh\t# building enterphone on vr180, used by the Apache proxy\n' >> /etc/hosts
  else echo "(already present or dry run)"; fi

  say "listen on the lan0 address only, https only (port 80 on lan0 belongs to the traffic-graph page)"
  put /etc/apache2/ports.conf 644 <<EOF
# written by setup-services.sh: https only, lan0 address only
Listen $ip:443
EOF
  put /etc/apache2/sites-available/cmpi-ssl.conf 644 <<EOF
# written by setup-services.sh; ported from the Pi's 000-default.conf (443 vhost)
<VirtualHost $ip:443>
    ServerName $SITE_NAME
    ServerAlias cpbee.cmnet
    ServerAdmin webmaster@localhost
    DocumentRoot /var/www/html
    ErrorLog \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined

    SSLEngine on
    SSLCertificateFile    /etc/ssl/Simple_Inc/certs/$CERT_NAME.crt
    SSLCertificateKeyFile /etc/ssl/Simple_Inc/certs/$CERT_NAME.key
    SSLProtocol all -SSLv3 -TLSv1 -TLSv1.1

    Header always set Content-Security-Policy "default-src https: data: 'unsafe-inline' 'unsafe-eval'"
    # No HSTS on purpose: browsers apply it to the whole host name, ignoring the port, so it would also force https on the plain-http
    # LibreNMS (:8080) and traffic graphs (:80). max-age=0 makes a browser that already stored one forget it.
    Header always set Strict-Transport-Security "max-age=0"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-Content-Type-Options "nosniff"

    # /mesh/ itself is an empty page on the mesh server (200, no body); its front page is the login. Send people there.
    RewriteEngine On
    RewriteRule ^/mesh/?\$ /mesh/jsp/login.jsp [R=302,L]

    # the building's mesh server only answers plain http (port 80) these days; /test/ is gone (404)
    ProxyRequests Off
    ProxyPass /mesh/ http://mesh/mesh/
    ProxyPassReverse /mesh/ http://mesh/mesh/
    <Location "/mesh/">
        ProxyHTMLEnable On
        ProxyHTMLExtended On
        ProxyPreserveHost Off
        RequestHeader unset Accept-Encoding
        ProxyHTMLURLMap http://mesh/mesh/ /mesh/
    </Location>
</VirtualHost>
EOF
  # start after networkd has put the address on lan0 (it is configured without carrier, but order it anyway)
  put /etc/systemd/system/apache2.service.d/10-after-network.conf 644 <<'EOF'
[Unit]
After=systemd-networkd.service
EOF
  run systemctl daemon-reload

  say "modules and site"
  run a2dismod -q mpm_prefork || true
  run a2enmod -q mpm_event ssl rewrite headers proxy proxy_http proxy_html xml2enc proxy_fcgi setenvif
  run a2enconf -q "php$PHPV-fpm"
  run a2dissite -q 000-default default-ssl || true
  run a2ensite -q cmpi-ssl

  say "site files (copy of the Pi's /var/www/html; the root-only 'f' folder is not included)"
  run rsync -rlptD --exclude=/f/ --exclude=/6767/ "$IMPORT/www/html/" /var/www/html/
  run chown -R www-data:www-data /var/www/html
  run rm -f /var/www/html/index.html.dist

  say "start"
  if [[ $DRY_RUN != 1 ]]; then apache2ctl configtest; fi
  run systemctl enable "php$PHPV-fpm" apache2
  run systemctl restart "php$PHPV-fpm" apache2
  open_port 443 "Apache https (setup-services.sh)"
  echo; echo "Done. Try from a lan0 machine:  https://$SITE_NAME/  (the site certificate is from the private 'Simple Signing CA'; DNS name $SITE_NAME must point at $ip)"
}

# ------------------------------------------------------------------ mail
mode_mail(){
  local ip net; ip=$(lan_ip); net=$(lan_net "$ip")
  [[ -r $SECRETS/sasl_passwd ]] || die "missing $SECRETS/sasl_passwd: run './bin/setup-services.sh fetch' first"
  echo "Postfix: satellite system, relay [u-l.ca]:465 (TLS on connect) with the Pi's login; listens on 127.0.0.1 and $ip; accepts mail from $net."
  confirm "Continue?"
  if [[ $DRY_RUN != 1 ]]; then
    printf 'postfix postfix/main_mailer_type select Satellite system\npostfix postfix/mailname string u-l.ca\npostfix postfix/relayhost string [u-l.ca]:465\n' | debconf-set-selections
  else echo "+ debconf: Satellite system, mailname u-l.ca, relayhost [u-l.ca]:465"; fi
  run apt-get update
  run apt-get install -y postfix libsasl2-modules bsd-mailx

  say "maps"
  put /etc/postfix/sasl_passwd 600 < "$SECRETS/sasl_passwd"
  # sender rewriting: local names -> the real address the Pi used (cwp@u-l.ca)
  { sed 's/^@cmpi\b/@cpbee/' "$SECRETS/generic"; printf '@cpbee.cmnet\tcwp@u-l.ca\n'; } | put /etc/postfix/generic 644
  sed 's/@cmpi$/@cpbee/; s/@cmpi\}/@cpbee}/' "$SECRETS/lan-canonical" | put /etc/postfix/lan-canonical 644
  if [[ $DRY_RUN != 1 ]]; then postmap /etc/postfix/sasl_passwd /etc/postfix/generic; chmod 600 /etc/postfix/sasl_passwd.db; fi

  say "main.cf"
  run postconf -e "myhostname = cpbee" "myorigin = \$myhostname" "mydestination = \$myhostname, localhost.\$mydomain, localhost" \
    "inet_interfaces = 127.0.0.1, $ip" "inet_protocols = ipv4" "mynetworks = 127.0.0.0/8, $net" \
    "relayhost = [u-l.ca]:465" "smtp_tls_wrappermode = yes" "smtp_tls_security_level = encrypt" "smtp_use_tls = yes" \
    "smtp_sasl_auth_enable = yes" "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd" \
    "smtp_sasl_security_options = noanonymous" "smtp_sasl_tls_security_options = noanonymous" \
    "smtp_generic_maps = hash:/etc/postfix/generic" "canonical_maps = regexp:/etc/postfix/lan-canonical" \
    "local_header_rewrite_clients = permit_inet_interfaces, permit_mynetworks" \
    "smtpd_relay_restrictions = permit_mynetworks, reject_unauth_destination" \
    "recipient_delimiter = +" "mailbox_size_limit = 0" "delay_warning_time = 1h" "notify_classes = resource, software, bounce, delay, 2bounce"
  if [[ $DRY_RUN != 1 ]] && ! grep -q '^root:' /etc/aliases; then echo 'root: chris' >> /etc/aliases; fi
  run newaliases
  put /etc/systemd/system/postfix@.service.d/10-after-network.conf 644 <<'EOF'
[Unit]
After=systemd-networkd.service
EOF
  run systemctl daemon-reload
  run systemctl enable postfix
  run systemctl restart postfix
  open_port 25 "Postfix smtp from the LAN (setup-services.sh)"
  echo; echo "Done. Test:  sudo ./bin/setup-services.sh mailtest you@example.com"
}

# ------------------------------------------------------------------ webmin
WEBMIN_PORT=10000
setconf(){   # setconf <file> <key> <value>   replace "key=..." or append it
  local f=$1 k=$2 v=$3
  if [[ $DRY_RUN == 1 ]]; then echo "+ set $k=$v in $f"; return 0; fi
  if grep -q "^$k=" "$f"; then sed -i "s|^$k=.*|$k=$v|" "$f"; else echo "$k=$v" >> "$f"; fi
}
webmin_tmp_setup(){   # Webmin's temp files on disk (/var/tmp) instead of the RAM-backed /tmp (Debian 13 mounts /tmp as tmpfs); Webmin warns about it in its UI
  local cf=/etc/webmin/config d=/var/tmp/.webmin
  [[ -f $cf || $DRY_RUN == 1 ]] || { echo "(no $cf: Webmin not installed)"; return 0; }
  run install -d -m 755 "$d"
  [[ $DRY_RUN == 1 ]] || bk "$cf"
  setconf "$cf" tempdir "$d"
}
mode_webmin_tmp(){ webmin_tmp_setup; run systemctl restart webmin; echo "Webmin temp files now in /var/tmp/.webmin (the same as Webmin Configuration > Advanced Options > Directory for temporary files)."; }
mode_webmin(){
  local ip adm; ip=$(lan_ip); adm=${WEBMIN_USER:-$RUN_USER}
  [[ -r $SECRETS/$CERT_NAME.crt && -r $SECRETS/$CERT_NAME.key ]] || die "missing $SECRETS/$CERT_NAME.{crt,key}: run './bin/setup-services.sh fetch' first"
  echo "Webmin from the official Webmin apt repository (download.webmin.com), https on $ip:$WEBMIN_PORT (lan0 only), site certificate,"
  echo "login = Unix account '$adm' (your normal password; no separate Webmin password is created). Needs the internet."
  confirm "Continue?"

  say "signing key"
  run apt-get update
  run apt-get install -y gnupg curl ca-certificates
  if [[ $DRY_RUN == 1 ]]; then echo "+ download https://download.webmin.com/developers-key.asc, show its fingerprint, cross-check keyserver.ubuntu.com, ask you to confirm"
  else
    local tmp fpr a; tmp=$(mktemp -d)
    curl -fsSL https://download.webmin.com/developers-key.asc -o "$tmp/key.asc"
    gpg --show-keys --with-colons "$tmp/key.asc" | awk -F: '$1=="fpr"{print $10}' > "$tmp/fprs"
    [[ -s $tmp/fprs ]] || die "no key found in the download"
    echo "Key in the file from download.webmin.com:"; gpg --show-keys "$tmp/key.asc" | sed 's/^/    /'
    fpr=$(head -1 "$tmp/fprs")
    if curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x$fpr" -o "$tmp/ks.asc" 2>/dev/null \
       && gpg --show-keys --with-colons "$tmp/ks.asc" 2>/dev/null | awk -F: '$1=="fpr"{print $10}' | grep -qx "$fpr"; then
      echo "keyserver.ubuntu.com has the same key (independent copy)."
    else echo "WARNING: could not find that fingerprint on keyserver.ubuntu.com"; fi
    if [[ -n ${WEBMIN_KEY_FPR:-} ]]; then
      grep -qx "${WEBMIN_KEY_FPR// /}" "$tmp/fprs" || die "WEBMIN_KEY_FPR does not match the downloaded key"
    else
      read -rp "Compare the fingerprint with the one Webmin publishes (webmin.com docs). Trust this key? [y/N] " a; [[ $a == y || $a == Y ]] || die "aborted"
    fi
    gpg --dearmor < "$tmp/key.asc" > /usr/share/keyrings/webmin.gpg; chmod 644 /usr/share/keyrings/webmin.gpg
    rm -rf "$tmp"
  fi
  put /etc/apt/sources.list.d/webmin.sources 644 <<'EOF'
Types: deb
URIs: https://download.webmin.com/download/newkey/repository
Suites: stable
Components: contrib
Signed-By: /usr/share/keyrings/webmin.gpg
EOF
  say "install"
  run apt-get update
  run apt-get install -y webmin

  say "configure: lan0 address only, https with the site certificate, login via Unix account $adm"
  local mc=/etc/webmin/miniserv.conf
  if [[ $DRY_RUN != 1 ]]; then
    [[ -f $mc ]] || die "$mc missing after install"
    bk "$mc"; bk /etc/webmin/miniserv.users; bk /etc/webmin/webmin.acl
    systemctl stop webmin || true
    sed -i '/^listen=/d' "$mc"
  fi
  setconf "$mc" port "$WEBMIN_PORT"
  setconf "$mc" bind "$ip"
  setconf "$mc" ssl 1
  setconf "$mc" keyfile /etc/ssl/Simple_Inc/certs/$CERT_NAME.key
  setconf "$mc" certfile /etc/ssl/Simple_Inc/certs/$CERT_NAME.crt
  setconf "$mc" ssl_redirect 1
  setconf "$mc" referers "$SITE_NAME cpbee cpbee.cmnet $ip"
  if [[ $DRY_RUN == 1 ]]; then echo "+ add '$adm:x:0' to /etc/webmin/miniserv.users and copy root's module list to $adm in /etc/webmin/webmin.acl"
  else
    grep -q "^$adm:" /etc/webmin/miniserv.users || echo "$adm:x:0" >> /etc/webmin/miniserv.users
    if ! grep -q "^$adm:" /etc/webmin/webmin.acl; then grep '^root:' /etc/webmin/webmin.acl | sed "s/^root:/$adm:/" >> /etc/webmin/webmin.acl; fi
    chmod 600 /etc/webmin/miniserv.users
  fi
  webmin_tmp_setup
  run systemctl enable webmin
  run systemctl restart webmin
  open_port "$WEBMIN_PORT" "Webmin https (setup-services.sh)"
  if [[ $DRY_RUN != 1 ]]; then
    sleep 3
    curl -ksS -m 10 -o /dev/null -w 'self-test https://%{remote_ip}:%{remote_port}/ -> %{http_code}\n' "https://$ip:$WEBMIN_PORT/" || echo "WARNING: Webmin did not answer"
  fi
  echo; echo "Done. Browse to https://$SITE_NAME:$WEBMIN_PORT/ (or https://$ip:$WEBMIN_PORT/) from a lan0 machine and log in as $adm."
  echo "The Pi's Webmin module settings are not migrated (fresh install)."
}

# ------------------------------------------------------------------ ftp / telnet (installed, NOT started: manual start only)
mode_ftp(){
  local ip; ip=$(lan_ip)
  echo "vsftpd: plain-text FTP, local users, listens on $ip only, passive ports 40000-40009. Installed stopped and disabled;"
  echo "start it with: sudo ./bin/setup-services.sh on ftp"
  echo "Like the Pi's config it is READ-ONLY (no write_enable); run this mode with FTP_WRITE=YES to allow uploads."
  confirm "Continue?"
  run apt-get update
  run apt-get install -y vsftpd
  put /etc/vsftpd.conf 644 <<EOF
# written by setup-services.sh (ported from the Pi's vsftpd.conf). Plain text: LAN only, started by hand.
listen=YES
listen_ipv6=NO
listen_address=$ip
anonymous_enable=NO
local_enable=YES
write_enable=${FTP_WRITE:-NO}
dirmessage_enable=YES
use_localtime=YES
xferlog_enable=YES
connect_from_port_20=YES
secure_chroot_dir=/var/run/vsftpd/empty
pam_service_name=vsftpd
ssl_enable=NO
pasv_enable=YES
pasv_min_port=40000
pasv_max_port=40009
pasv_address=$ip
EOF
  run systemctl disable --now vsftpd
  echo; echo "vsftpd installed, stopped and disabled."
}
mode_telnet(){
  local ip; ip=$(lan_ip)
  echo "telnetd (inetutils): plain-text telnet on $ip:23 through a systemd socket. Installed disabled;"
  echo "start it with: sudo ./bin/setup-services.sh on telnet"
  confirm "Continue?"
  run apt-get update
  run apt-get install -y inetutils-telnetd
  put /etc/systemd/system/telnet.socket 644 <<EOF
[Unit]
Description=Telnet socket (manual start only, LAN address)
[Socket]
ListenStream=$ip:23
FreeBind=yes
Accept=yes
[Install]
WantedBy=sockets.target
EOF
  put /etc/systemd/system/telnet@.service 644 <<'EOF'
[Unit]
Description=Telnet session %I
[Service]
ExecStart=-/usr/sbin/telnetd
StandardInput=socket
StandardOutput=socket
StandardError=journal
EOF
  run systemctl daemon-reload
  run systemctl disable --now telnet.socket || true
  echo; echo "telnet.socket installed and NOT enabled (it does not start at boot)."
}
# on|off <ftp|telnet>: start/stop the service and open/close its port to lan0 in the LIVE firewall only (a reboot or `setup-router.sh fw` closes it)
svc_unit(){ case $1 in ftp) echo vsftpd;; telnet) echo telnet.socket;; *) die "unknown service '$1' (ftp|telnet)";; esac; }
svc_ports(){ case $1 in ftp) echo "21, 40000-40009";; telnet) echo "23";; esac; }
nft_drop_rules(){ local tag=$1 h; for h in $(nft -a list chain inet filter input | sed -n "s/.*comment \"$tag\" # handle \([0-9]*\)\$/\1/p"); do nft delete rule inet filter input handle "$h"; done; }
mode_on(){
  local s=${2:-} unit; unit=$(svc_unit "$s")
  systemctl cat "$unit" >/dev/null 2>&1 || die "$s is not installed: run '$0 $s' first"
  nft_drop_rules "svc-$s"
  nft add rule inet filter input iifname '"lan0"' tcp dport "{ $(svc_ports "$s") }" accept comment "\"svc-$s\""
  systemctl start "$unit"
  echo "$s is ON ($unit running, port(s) $(svc_ports "$s") open to lan0). Turn it off with: sudo $0 off $s"
}
mode_off(){
  local s=${2:-} unit; unit=$(svc_unit "$s")
  systemctl stop "$unit" 2>/dev/null || true
  if [[ $s == telnet ]]; then systemctl stop 'telnet@*.service' 2>/dev/null || true; fi
  nft_drop_rules "svc-$s"
  echo "$s is OFF (service stopped, firewall rule removed)."
}
mode_status(){
  local s fw
  for s in ftp telnet; do
    fw=closed; nft -a list chain inet filter input 2>/dev/null | grep -q "svc-$s" && fw=open
    printf '%-7s %-14s enabled=%-9s active=%-9s firewall=%s\n' "$s" "$(svc_unit $s)" "$(systemctl is-enabled "$(svc_unit $s)" 2>&1 | head -1)" "$(systemctl is-active "$(svc_unit $s)" 2>&1)" "$fw"
  done
  printf 'webmin  enabled=%s active=%s\n' "$(systemctl is-enabled webmin 2>&1 | head -1)" "$(systemctl is-active webmin 2>&1)"
}

# ------------------------------------------------------------------ check / mailtest
mode_check(){
  local ip; ip=$(lan_ip); local bad=0
  ok(){ printf '[ ok ] %s\n' "$*"; }; no(){ printf '[FAIL] %s\n' "$*"; bad=1; }
  for s in apache2 postfix; do systemctl is-active --quiet "$s" && ok "$s active" || no "$s not active"; done
  systemctl list-units 'php*-fpm.service' --no-legend | grep -q running && ok "php-fpm running" || no "php-fpm not running"
  echo "-- listening sockets"; ss -ltnH | awk '$4 ~ /:(443|25)$/ {print "   " $4}'
  ss -ltnH | awk '$4 ~ /:(443|25)$/ {print $4}' | grep -Ev "^($ip|127\.0\.0\.1):" | grep -q . && no "a service listens on an address other than $ip/127.0.0.1" || ok "443/25 bound to $ip and loopback only"
  curl -ksS -m 10 -o /dev/null -w '%{http_code}' --resolve "$SITE_NAME:443:$ip" "https://$SITE_NAME/" | { read -r c || true; [[ $c =~ ^(200|301|302|403)$ ]] && ok "https://$SITE_NAME/ answers $c" || no "https://$SITE_NAME/ answered '$c'"; }
  postqueue -p 2>/dev/null | tail -1 | sed 's/^/   mail queue: /'
  grep -Eq '^(443|25)\b' "$LAN_PORTS_FILE" 2>/dev/null && ok "firewall ports listed in $LAN_PORTS_FILE: $(grep -Eo '^[0-9]+' "$LAN_PORTS_FILE" | tr '\n' ' ')" || no "443/25 not in $LAN_PORTS_FILE"
  return $bad
}
mode_mailtest(){
  local to=${2:-}; [[ $to =~ ^[^@[:space:]]+@[^@[:space:]]+$ ]] || die "usage: mailtest you@example.com"
  printf 'Subject: cpbee mail test %s\nTo: %s\n\nSent by setup-services.sh mailtest through the u-l.ca relay.\n' "$(date +%F-%T)" "$to" | sendmail -f "${MAILTEST_FROM:-chris@cpbee}" "$to"
  sleep 4; postqueue -p; grep -E "status=" /var/log/mail.log 2>/dev/null | tail -3 || journalctl -u postfix@- -n 5 --no-pager
}

# ------------------------------------------------------------------ cert: swap the https certificate on the running Apache and Webmin
#   sudo ./bin/setup-services.sh cert        installs $SECRETS/$CERT_NAME.{crt,key} (+ .chn chain bundle when present), points Apache and Webmin at them
mode_cert(){
  [[ -r $SECRETS/$CERT_NAME.crt && -r $SECRETS/$CERT_NAME.key ]] || die "missing $SECRETS/$CERT_NAME.{crt,key}"
  openssl x509 -in "$SECRETS/$CERT_NAME.crt" -noout -checkend 0 >/dev/null || die "certificate expired"
  [[ $(openssl x509 -in "$SECRETS/$CERT_NAME.crt" -noout -pubkey | sha256sum) == $(openssl pkey -in "$SECRETS/$CERT_NAME.key" -pubout | sha256sum) ]] || die "certificate and key do not match"
  openssl x509 -in "$SECRETS/$CERT_NAME.crt" -noout -ext subjectAltName | grep -q "DNS:$SITE_NAME" || die "the certificate does not carry the name $SITE_NAME"
  local ip; ip=$(lan_ip)
  say "install files"
  run install -d -m 755 /etc/ssl/Simple_Inc/certs
  run install -m 644 "$([[ -r $SECRETS/$CERT_NAME.chn ]] && echo "$SECRETS/$CERT_NAME.chn" || echo "$SECRETS/$CERT_NAME.crt")" "/etc/ssl/Simple_Inc/certs/$CERT_NAME.crt"
  run install -m 600 -o root -g root "$SECRETS/$CERT_NAME.key" "/etc/ssl/Simple_Inc/certs/$CERT_NAME.key"
  # the CA part of the bundle (signing + root) as its own file: Webmin loads only the first certificate of certfile and sends the chain from its `extracas` store
  local chainfile=/etc/ssl/Simple_Inc/certs/$CERT_NAME-chain.pem
  if [[ -r $SECRETS/$CERT_NAME.chn ]]; then
    if [[ $DRY_RUN == 1 ]]; then echo "+ write $chainfile (certificates 2..n of $CERT_NAME.chn)"
    else awk '/BEGIN CERTIFICATE/{c++} c>=2' "$SECRETS/$CERT_NAME.chn" > "$chainfile"; chmod 644 "$chainfile"; fi
  fi
  local site=/etc/apache2/sites-available/cmpi-ssl.conf
  if [[ -f $site ]]; then
    say "Apache: $site"
    if [[ $DRY_RUN == 1 ]]; then echo "+ sed: SSLCertificateFile/KeyFile -> $CERT_NAME, ServerName $SITE_NAME, ServerAlias cpbee.cmnet; apache2ctl configtest; restart"
    else
      bk "$site"
      sed -i -E "s#^([[:space:]]*SSLCertificateFile[[:space:]]+).*#\1/etc/ssl/Simple_Inc/certs/$CERT_NAME.crt#; s#^([[:space:]]*SSLCertificateKeyFile[[:space:]]+).*#\1/etc/ssl/Simple_Inc/certs/$CERT_NAME.key#; s#^([[:space:]]*ServerName[[:space:]]+).*#\1$SITE_NAME#; s#^([[:space:]]*ServerAlias[[:space:]]+).*#\1cpbee.cmnet#" "$site"
      apache2ctl configtest && systemctl restart apache2
    fi
  else echo "(no Apache site $site: nothing to change)"; fi
  local mc=/etc/webmin/miniserv.conf
  if [[ -f $mc ]]; then
    say "Webmin: $mc"
    [[ $DRY_RUN == 1 ]] || bk "$mc"
    setconf "$mc" keyfile "/etc/ssl/Simple_Inc/certs/$CERT_NAME.key"
    setconf "$mc" certfile "/etc/ssl/Simple_Inc/certs/$CERT_NAME.crt"
    [[ -r $SECRETS/$CERT_NAME.chn ]] && setconf "$mc" extracas "$chainfile"
    setconf "$mc" referers "$SITE_NAME cpbee.cmnet $ip"
    run systemctl restart webmin
  fi
  if [[ $DRY_RUN != 1 ]]; then
    sleep 2
    echo | openssl s_client -connect "$ip:443" -servername "$SITE_NAME" 2>/dev/null | openssl x509 -noout -subject -ext subjectAltName 2>/dev/null | sed 's/^/  Apache serves: /'
    echo | openssl s_client -connect "$ip:$WEBMIN_PORT" -servername "$SITE_NAME" 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | sed 's/^/  Webmin serves: /'
  fi
  echo; echo "Done. Browsers must trust your Simple Root CA (Simple_Inc/ca/root-ca.crt) to show no warning at https://$SITE_NAME/ and https://$SITE_NAME:$WEBMIN_PORT/"
}

# ------------------------------------------------------------------ nohsts
mode_nohsts(){
  local site=/etc/apache2/sites-available/cmpi-ssl.conf mc=/etc/webmin/miniserv.conf
  if [[ -f $site ]]; then
    say "Apache: $site"
    if [[ $DRY_RUN == 1 ]]; then echo "+ sed: Strict-Transport-Security -> \"max-age=0\"; apache2ctl configtest; reload"
    else
      bk "$site"
      sed -i -E 's#^([[:space:]]*Header always set Strict-Transport-Security ).*#\1"max-age=0"#' "$site"
      apache2ctl configtest && systemctl reload apache2
    fi
  else echo "(no Apache site $site)"; fi
  if [[ -f $mc ]]; then
    say "Webmin: $mc"
    [[ $DRY_RUN == 1 ]] || bk "$mc"
    setconf "$mc" ssl_hsts 0
    # ssl_enforce=2 is Webmin's own "redirect and HSTS" choice (it re-sets ssl_hsts=1 from it); 1 = redirect only
    if [[ $DRY_RUN != 1 ]] && grep -q '^ssl_enforce=2' "$mc"; then sed -i 's/^ssl_enforce=2/ssl_enforce=1/' "$mc"; fi
    run systemctl restart webmin
  fi
  if [[ $DRY_RUN != 1 ]]; then
    sleep 2
    local ip; ip=$(lan_ip)
    echo "Headers now (both should show max-age=0):"
    curl -sk -m 8 -D - -o /dev/null "https://$ip/" | grep -i '^strict' | sed 's/^/  Apache: /'
    curl -sk -m 8 -D - -o /dev/null "https://$ip:$WEBMIN_PORT/" | grep -i '^strict' | sed 's/^/  Webmin: /'
  fi
  cat <<EOT

Browsers that already stored HSTS for the name keep it until they SEE a max-age=0 over https (or you clear it by hand).
Open each of these once in every browser you used, then http://$SITE_NAME:8080/ stays http:
    https://$SITE_NAME/    https://$SITE_NAME:$WEBMIN_PORT/    (and the same with cpbee.cmnet if you used that name)
By hand instead: Chrome/Edge chrome://net-internals/#hsts -> "Delete domain security policies" -> $SITE_NAME;
Firefox: Ctrl+Shift+Del -> Site settings / "Forget about this site" for $SITE_NAME.
Using the IP (http://192.168.10.1:8080/) is never affected: HSTS does not apply to IP addresses.
EOT
}

# ------------------------------------------------------------------ pma-user
mode_pma_user(){
  command -v mariadb >/dev/null || die "mariadb client not found"
  local u p p2 q
  u=${PMA_USER:-$RUN_USER}
  [[ $u =~ ^[a-z_][a-z0-9_-]*$ ]] || die "bad user name '$u' (PMA_USER=...)"
  echo "phpMyAdmin cannot log in as root: MariaDB's root@localhost authenticates by unix socket (ERROR 1698), which a web page cannot use."
  echo "This creates (or resets) the MariaDB login '$u'@'localhost' with ALL privileges (and GRANT OPTION). root stays socket-only, so 'sudo mariadb' still works."
  if [[ $DRY_RUN == 1 ]]; then
    echo "+ read a password for '$u' twice (hidden)"
    echo "+ mariadb < CREATE USER IF NOT EXISTS '$u'@'localhost'; ALTER USER '$u'@'localhost' IDENTIFIED BY '<password>'; GRANT ALL PRIVILEGES ON *.* TO '$u'@'localhost' WITH GRANT OPTION; FLUSH PRIVILEGES;"
    return 0
  fi
  read -rsp "Password for MariaDB user '$u': " p; echo
  read -rsp "Again: " p2; echo
  [[ -n $p && $p == "$p2" ]] || die "empty or different passwords: nothing changed"
  q=${p//\\/\\\\}; q=${q//\'/\\\'}   # SQL string escaping (the password never appears on a command line)
  mariadb <<SQL
CREATE USER IF NOT EXISTS '$u'@'localhost' IDENTIFIED BY '$q';
ALTER USER '$u'@'localhost' IDENTIFIED BY '$q';
GRANT ALL PRIVILEGES ON *.* TO '$u'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
  echo "Done. Log in at https://$SITE_NAME/phpmyadmin/ as '$u' with that password."
  echo "Note: phpMyAdmin's own control user ('phpmyadmin', from dbconfig-common) is separate and is not touched."
}

# ------------------------------------------------------------------ tls
# Every plain-http web page gets https. Apache (443) and Webmin (10000) already have it. nginx (already installed for LibreNMS) becomes the TLS front:
#   LibreNMS        nginx :8080 -> same listener, now ssl (plain http on 8080 is redirected to https)
#   traffic graphs  python moves to 127.0.0.1:8081 (so it never touches the key); nginx :8443 ssl proxies to it; nginx :80 only redirects to https://<name>:8443/
#   later (waxweb)  same pattern: backend on loopback, one more nginx server block, one more line in /etc/router-setup/lan0-tcp-ports
# No HSTS anywhere (see nohsts).
mode_tls(){
  local ip crt key snip lnms tg unit lback=127.0.0.1 bport tport lport have_tg=0
  ip=$(lan_ip); bport=${GRAPH_BACKEND_PORT:-8081}; tport=${GRAPH_TLS_PORT:-8443}
  crt=/etc/ssl/Simple_Inc/certs/$CERT_NAME.crt; key=/etc/ssl/Simple_Inc/certs/$CERT_NAME.key
  snip=/etc/nginx/snippets/cpbee-tls.conf; lnms=/etc/nginx/conf.d/librenms.conf; tg=/etc/nginx/conf.d/trafficgraph-tls.conf
  unit=/etc/systemd/system/trafficgraph.service
  [[ $bport =~ ^[0-9]+$ && $tport =~ ^[0-9]+$ ]] || die "bad GRAPH_BACKEND_PORT / GRAPH_TLS_PORT"
  if [[ $DRY_RUN != 1 ]]; then
    [[ -r $crt && -r $key ]] || die "missing $crt / $key: run 'setup-services.sh cert' first"
    command -v nginx >/dev/null || die "nginx is not installed (it comes with 'setup-monitoring.sh librenms')"
    [[ -f $unit ]] || echo "NOTE: no $unit: the traffic graphs are not installed (setup-router.sh graphs); only LibreNMS gets https"
  fi
  [[ $DRY_RUN == 1 || -f $unit ]] && have_tg=1

  say "nginx TLS settings: $snip (certificate $CERT_NAME)"
  put "$snip" 644 <<EOF
# shared by every https server block on cpbee (written by setup-services.sh tls)
ssl_certificate     $crt;
ssl_certificate_key $key;
ssl_protocols       TLSv1.2 TLSv1.3;
ssl_session_cache   shared:cpbee_tls:2m;
ssl_session_timeout 1h;
EOF

  if (( have_tg )); then
    say "traffic graphs: nginx :$tport (https) -> 127.0.0.1:$bport, :80 redirects"
    put "$tg" 644 <<EOF
# written by setup-services.sh tls: https front for the traffic graphs (the python service listens on 127.0.0.1:$bport only)
server {
 listen $ip:$tport ssl;
 include snippets/cpbee-tls.conf;
 server_name _;
 server_tokens off;
 error_page 497 =301 https://\$host:\$server_port\$request_uri;
 location / {
  proxy_pass http://127.0.0.1:$bport;
  proxy_http_version 1.1;
  proxy_set_header Host \$host;
  proxy_set_header X-Forwarded-Proto https;
  proxy_read_timeout 60s;
 }
}
server {
 listen $ip:80;
 server_name _;
 server_tokens off;
 return 301 https://\$host:$tport\$request_uri;
}
EOF
  fi

  if [[ -f $lnms ]] && ! grep -q 'cpbee-tls.conf' "$lnms"; then
    say "LibreNMS: $lnms -> ssl on its existing listener"
    if [[ $DRY_RUN == 1 ]]; then echo "+ sed: 'listen $ip:<port>;' -> 'listen $ip:<port> ssl;' + include snippets/cpbee-tls.conf + error_page 497 -> https"
    else
      bk "$lnms"
      sed -i -E '0,/^([[:space:]]*listen[[:space:]]+[0-9.]+:[0-9]+)[[:space:]]*;/ s//\1 ssl;\n include snippets\/cpbee-tls.conf;\n error_page 497 =301 https:\/\/$host:$server_port$request_uri;/' "$lnms"
    fi
  elif [[ ! -f $lnms ]]; then echo "(no $lnms: LibreNMS not installed here)"; fi

  say "nginx: test the configuration before touching anything live"
  if [[ $DRY_RUN == 1 ]]; then echo "+ nginx -t   (on failure: restore $lnms from $BK, remove $tg; nothing else changed)"
  elif ! nginx -t; then
    [[ -e $BK$lnms ]] && cp -a "$BK$lnms" "$lnms"; rm -f "$tg"
    die "nginx -t failed: nginx files restored, nothing else was changed"
  fi

  if (( have_tg )); then
    say "traffic graphs service -> 127.0.0.1:$bport, remembered for setup-router.sh graphs"
    put /etc/router-setup/graphs-backend 644 <<EOF
$lback $bport https://$SITE_NAME:$tport/
EOF
    if [[ $DRY_RUN == 1 ]]; then echo "+ edit $unit: TRAFFIC_BIND=$lback TRAFFIC_PORT=$bport TRAFFIC_URL=https://$SITE_NAME:$tport/ ; daemon-reload ; restart trafficgraph"
    else
      bk "$unit"
      sed -i -E "s/TRAFFIC_BIND=[0-9.]+/TRAFFIC_BIND=$lback/; s/TRAFFIC_PORT=[0-9]+/TRAFFIC_PORT=$bport/; s# TRAFFIC_URL=[^ ]*##; s#^(Environment=TRAFFIC_BIND=.*)\$#\1 TRAFFIC_URL=https://$SITE_NAME:$tport/#" "$unit"
      systemctl daemon-reload; systemctl restart trafficgraph
    fi

    say "firewall: lan0 may reach 80 (redirect) and $tport (https graphs); the old direct rule for the python port goes away"
    if [[ $DRY_RUN == 1 ]]; then echo "+ add 80 and $tport to $LAN_PORTS_FILE, run setup-router.sh fw"
    else
      install -d /etc/router-setup; touch "$LAN_PORTS_FILE"
      for lport in 80 "$tport"; do
        grep -Eq "^[[:space:]]*$lport([[:space:]]|\$)" "$LAN_PORTS_FILE" || printf '%s  # %s\n' "$lport" "$([[ $lport == 80 ]] && echo 'http to https redirect (nginx)' || echo 'traffic graphs https (nginx)')" >> "$LAN_PORTS_FILE"
      done
      local sr; sr="$(dirname "$(readlink -f "$0")")/setup-router.sh"
      [[ -x $sr ]] && "$sr" fw || echo "NOTE: run 'sudo ./bin/setup-router.sh fw' to load the new firewall rules"
    fi
  fi

  run systemctl restart nginx
  if [[ $DRY_RUN != 1 ]]; then
    sleep 2
    echo; echo "Checks:"
    local c lp
    if (( have_tg )); then
      c=$(curl -sk -m 8 -o /dev/null -w '%{http_code}' "https://$ip:$tport/api/config" || true); [[ $c == 200 ]] && echo "  [ ok ] https://$ip:$tport/api/config -> 200" || echo "  [FAIL] https://$ip:$tport/api/config -> $c (journalctl -u trafficgraph -u nginx)"
      c=$(curl -s -m 8 -o /dev/null -w '%{http_code} %{redirect_url}' "http://$ip/" || true);     [[ $c == 301* ]] && echo "  [ ok ] http://$ip/ -> $c" || echo "  [FAIL] http://$ip/ -> $c"
      c=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://$ip:$bport/" 2>/dev/null || true);  [[ $c == 000 ]] && echo "  [ ok ] the backend port $bport is not reachable on the lan0 address" || echo "  [warn] $ip:$bport answered $c"
    fi
    if [[ -f $lnms ]]; then
      lp=$(sed -n -E 's/^[[:space:]]*listen[[:space:]]+[0-9.]+:([0-9]+).*/\1/p' "$lnms" | head -1)
      c=$(curl -sk -m 8 -o /dev/null -w '%{http_code}' "https://$ip:$lp/login" || true);          [[ $c == 200 ]] && echo "  [ ok ] https://$ip:$lp/login -> 200" || echo "  [FAIL] https://$ip:$lp/login -> $c"
      c=$(curl -s -m 8 -o /dev/null -w '%{http_code}' "http://$ip:$lp/" || true);                 [[ $c == 301 ]] && echo "  [ ok ] http://$ip:$lp/ -> 301 (redirect to https)" || echo "  [warn] http://$ip:$lp/ -> $c"
      if grep -qE '^APP_URL=http://' /opt/librenms/.env 2>/dev/null; then echo "  [note] /opt/librenms/.env has APP_URL=http://...: change it to https://$SITE_NAME:$lp (links in LibreNMS mails use it), then: (cd /opt/librenms; sudo -u librenms php artisan config:clear)"; fi
    fi
    echo | openssl s_client -connect "$ip:${lp:-$tport}" -servername "$SITE_NAME" 2>/dev/null | openssl x509 -noout -subject -ext subjectAltName 2>/dev/null | sed 's/^/  cert: /'
  fi
  cat <<EOT

Now all https, certificate from your Simple CA, no HSTS:
    https://$SITE_NAME/             Apache + phpMyAdmin (/phpmyadmin/)
    https://$SITE_NAME:$tport/       traffic graphs   (http://$SITE_NAME/ redirects here)
    https://$SITE_NAME:8080/        LibreNMS         (http://$SITE_NAME:8080/ redirects here)
    https://$SITE_NAME:10000/       Webmin
A new service later (e.g. waxweb): listen on 127.0.0.1:<port>, add an nginx server block like $tg, add its port to $LAN_PORTS_FILE, run setup-router.sh fw.
EOT
}

# ------------------------------------------------------------------ servers
# The "servers list" page: https://<name>/servers/ . Source = ../www/servers.html next to this script's folder; the page builds its links from the host name it was opened with.
mode_servers(){
  local src dst=/var/www/html/servers/index.html
  src="$(dirname "$(readlink -f "$0")")/../www/servers.html"
  local st="$(dirname "$src")/servers-status.php"
  [[ -r $src && -r $st ]] || die "missing $src or $st"
  say "servers list page -> $dst (+ status.php: tests ssh, smtp, ftp, telnet, the VAX and mesh from cpbee)"
  run install -d -m 755 /var/www/html/servers
  put "$dst" 644 < "$src"
  put /var/www/html/servers/status.php 644 < "$st"
  [[ -d /var/www/html/servers/admin ]] && put /var/www/html/servers/admin/index.html 644 < "$src"   # the logged-in page is the same file
  # the Pi's old /status.php (copied with the site; it checks Apache on localhost, which cpbee does not listen on) now redirects here; the old file is kept in $BK
  put /var/www/html/status.php 644 <<'EOF'
<?php
// written by setup-services.sh servers: the old Pi "Service Status" page moved to /servers/ (the original is in /root/services-setup-backup-*)
header('Location: /servers/', true, 302);
exit;
EOF
  if [[ $DRY_RUN != 1 ]]; then
    local ip c; ip=$(lan_ip)
    c=$(curl -sk -m 8 -o /dev/null -w '%{http_code}' "https://$ip/servers/" || true)
    [[ $c == 200 ]] && echo "  [ ok ] https://$ip/servers/ -> 200" || echo "  [FAIL] https://$ip/servers/ -> $c"
    echo "  status.php says: $(curl -sk -m 12 "https://$ip/servers/status.php" || echo 'no answer')"
    c=$(curl -sk -m 8 -o /dev/null -w '%{http_code} %{redirect_url}' "https://$ip/status.php" || true)
    [[ $c == "302 "*"/servers/" ]] && echo "  [ ok ] https://$ip/status.php -> $c" || echo "  [FAIL] https://$ip/status.php -> $c"
  fi
  echo "Open https://$SITE_NAME/servers/   (re-run this after editing www/servers.html)"
}

# ------------------------------------------------------------------ pma-quiet
# Debian 13's php-twig (3.27) is newer than what phpMyAdmin 5.2.2 and php-twig-i18n-extension were written for, so every page shows
# "Since twig/twig 3.21: Method ... is deprecated" notices. phpMyAdmin shows E_USER_DEPRECATED even when PHP's error_reporting hides it
# (ErrorHandler::handleError), so php.ini cannot silence them. This conf.d file (read by Debian's config.inc.php, survives package upgrades)
# puts a filter in front of phpMyAdmin's own error handler that drops only the twig deprecations; every other error still reaches phpMyAdmin.
mode_pma_quiet(){
  [[ -d /etc/phpmyadmin || $DRY_RUN == 1 ]] || die "phpMyAdmin is not installed (no /etc/phpmyadmin)"
  put /etc/phpmyadmin/conf.d/10-quiet-twig-deprecations.php 644 <<'EOF'
<?php
// written by setup-services.sh pma-quiet. Remove this file to see the twig deprecation notices again.
// Debian 13 php-twig is newer than phpMyAdmin 5.2.2 expects; its "Since twig/twig x.y: ... is deprecated" notices are harmless, so drop only those.
(static function () {
    $previous = set_error_handler(static function () { return false; });   // returns phpMyAdmin's handler (registered before this file is read)
    set_error_handler(static function (int $errno, string $errstr, string $errfile = '', int $errline = 0) use ($previous) {
        if ($errno === E_USER_DEPRECATED && strncmp($errstr, 'Since twig/twig ', 16) === 0) {
            return true;
        }
        if ($previous !== null) {
            return $previous($errno, $errstr, $errfile, $errline);
        }
        return false;
    });
})();
EOF
  echo "Reload a phpMyAdmin page: the twig notices should be gone. (php-fpm needs no restart: the file is read on every request.)"
}

# ------------------------------------------------------------------ servers-admin
# The logged-in servers page: https://<name>/servers/admin/ = the same page (www/servers.html) with start/stop/restart buttons.
#   - Apache asks for a login there (HTTP Basic over https, /etc/apache2/cpbee-admin.htpasswd; the user is $ADMIN_USER, default the one who ran sudo,
#     and the password is asked, hidden, if that user is not in the file yet - re-run with ADMIN_PASSWORD_RESET=1 to change it);
#   - control.php (www/servers-control.php) there refuses to run without that login and without our own header, and hands every request to
#     /usr/local/sbin/cpbee-service (bin/cpbee-service), the one program www-data may run through sudo (/etc/sudoers.d/cpbee-servers).  That
#     helper holds the table of services and the actions allowed for each, and logs each press (journalctl -t cpbee-service).
mode_servers_admin(){
  local root src_html src_php src_svc ip c
  root="$(dirname "$(readlink -f "$0")")/.."
  src_html="$root/www/servers.html"; src_php="$root/www/servers-control.php"; src_svc="$root/bin/cpbee-service"
  local f; for f in "$src_html" "$src_php" "$src_svc"; do [[ -r $f ]] || die "missing $f"; done
  local admin=${ADMIN_USER:-$RUN_USER} htp=/etc/apache2/cpbee-admin.htpasswd
  [[ $admin =~ ^[A-Za-z0-9._-]{1,32}$ ]] || die "ADMIN_USER '$admin' is not a plain user name"
  command -v htpasswd >/dev/null 2>&1 || [[ $DRY_RUN == 1 ]] || die "htpasswd is missing: sudo apt install apache2-utils"

  say "1/5 the helper /usr/local/sbin/cpbee-service (root:root 755) and its sudoers line"
  put /usr/local/sbin/cpbee-service 755 < "$src_svc"
  put /etc/sudoers.d/cpbee-servers 440 <<'EOF'
# written by setup-services.sh servers-admin: the web server's user may run this one program, and only it, as root.
# The program holds the list of services and the actions allowed for each; nothing else is reachable.
www-data ALL=(root) NOPASSWD: /usr/local/sbin/cpbee-service
EOF
  if [[ $DRY_RUN != 1 ]]; then
    visudo -cf /etc/sudoers.d/cpbee-servers >/dev/null || { rm -f /etc/sudoers.d/cpbee-servers; die "visudo did not accept the sudoers line: removed it"; }
  fi

  say "2/5 the pages in /var/www/html/servers/admin/"
  run install -d -m 755 /var/www/html/servers/admin
  put /var/www/html/servers/admin/index.html 644 < "$src_html"
  put /var/www/html/servers/admin/control.php 644 < "$src_php"

  say "3/5 the login for '$admin' in $htp"
  if [[ $DRY_RUN == 1 ]]; then
    echo "+ htpasswd -B (password asked, hidden) -> $htp (mode 640, root:www-data)"
  elif [[ -f $htp ]] && grep -q "^$admin:" "$htp" && [[ ${ADMIN_PASSWORD_RESET:-0} != 1 ]]; then
    echo "  '$admin' is already in $htp (ADMIN_PASSWORD_RESET=1 sets a new password)"
  else
    local p1 p2
    read -rsp "  password for the servers page, user '$admin': " p1; echo
    read -rsp "  again: " p2; echo
    [[ -n $p1 && $p1 == "$p2" ]] || die "the two passwords differ (or are empty): nothing changed"
    bk "$htp"
    printf '%s\n' "$p1" | htpasswd -iB $([[ -f $htp ]] || echo -c) "$htp" "$admin" >/dev/null
    chown root:www-data "$htp"; chmod 640 "$htp"
  fi

  say "4/5 Apache: a login on /servers/admin/"
  put /etc/apache2/conf-available/cpbee-servers-admin.conf 644 <<'EOF'
# written by setup-services.sh servers-admin
<Directory /var/www/html/servers/admin>
    AuthType Basic
    AuthName "cpbee admin"
    AuthUserFile /etc/apache2/cpbee-admin.htpasswd
    Require valid-user
    Options -Indexes
    Header always set Cache-Control "no-store"
</Directory>
EOF
  if [[ $DRY_RUN == 1 ]]; then
    echo "+ a2enconf cpbee-servers-admin; apache2ctl configtest; systemctl reload apache2"
  else
    a2enconf -q cpbee-servers-admin
    if apache2ctl configtest >/dev/null 2>&1; then systemctl reload apache2
    else apache2ctl configtest; a2disconf -q cpbee-servers-admin; die "Apache did not accept the new config: the login conf is switched off again"; fi
  fi

  say "5/5 checks"
  if [[ $DRY_RUN != 1 ]]; then
    ip=$(lan_ip)
    c=$(curl -sk -m 8 -o /dev/null -w '%{http_code}' "https://$ip/servers/admin/" || true)
    [[ $c == 401 ]] && echo "  [ ok ] https://$ip/servers/admin/ without a login -> 401" || echo "  [FAIL] https://$ip/servers/admin/ without a login -> $c (should be 401)"
    c=$(curl -sk -m 8 -o /dev/null -w '%{http_code}' "https://$ip/servers/admin/control.php" || true)
    [[ $c == 401 ]] && echo "  [ ok ] https://$ip/servers/admin/control.php without a login -> 401" || echo "  [FAIL] control.php without a login -> $c (should be 401)"
    c=$(curl -sk -m 8 -o /dev/null -w '%{http_code}' "https://$ip/servers/" || true)
    [[ $c == 200 ]] && echo "  [ ok ] https://$ip/servers/ (public) -> 200" || echo "  [FAIL] https://$ip/servers/ -> $c"
    if sudo -u www-data sudo -n /usr/local/sbin/cpbee-service list >/dev/null 2>&1; then echo "  [ ok ] www-data may run cpbee-service through sudo"
    else echo "  [FAIL] www-data could not run cpbee-service through sudo (sudo -u www-data sudo -n /usr/local/sbin/cpbee-service list)"; fi
    echo "  the helper lists: $(/usr/local/sbin/cpbee-service list | cut -d'|' -f1,2 | tr '\n' ' ')"
  fi
  echo "Open https://$SITE_NAME/servers/admin/  and log in as '$admin'.  (Re-run 'servers' or this after editing www/servers.html.)"
}

case "${1:-}" in
  pma-quiet) mode_pma_quiet;;
  nohsts) mode_nohsts;; pma-user) mode_pma_user;; tls) mode_tls;; servers) mode_servers;; servers-admin) mode_servers_admin;; webmin-tmp) mode_webmin_tmp;;
  fetch) mode_fetch;; web) mode_web;; mail) mode_mail;; check) mode_check;; mailtest) mode_mailtest "$@";;
  cert) mode_cert;; webmin) mode_webmin;; ftp) mode_ftp;; telnet) mode_telnet;; on) mode_on "$@";; off) mode_off "$@";; status) mode_status;;
  *) sed -n '2,20p' "$0"; exit 1;;
esac
