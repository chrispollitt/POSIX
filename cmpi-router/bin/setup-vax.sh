#!/usr/bin/env bash
# The VAX (simh MicroVAX 3900, "cpvax") moved from cmpi to cpbee. MANUAL START ONLY: the unit is never enabled.
#
#   sudo ./bin/setup-vax.sh deps       build tools (build-essential, libpcap-dev, ...)           needs the internet
#   ./bin/setup-vax.sh build           (NOT root) download open-simh (Debian 13 has no simh package) and build only the `vax` simulator in ~/simh-build
#   sudo ./bin/setup-vax.sh install    simh user, /var/simh/vax (from ~/cmpi-import/vax), vax.ini, tap interface "vaxtap", firewall zone, vax.service (disabled)
#   sudo ./bin/setup-vax.sh check      what is in place
#   afterwards:  sudo systemctl start vax | stop vax | status vax     console: telnet 127.0.0.1 2323 (on cpbee; from elsewhere: ssh -L 2323:127.0.0.1:2323 cpbee)
#
# Network (option 3, chosen 2026-10-10): the VAX sits on its own routed subnet behind cpbee, lan0 is untouched.
#   cpbee side  vaxtap 192.168.20.1/24      VAX (VMS/TCPware) 192.168.20.30, gateway 192.168.20.1, name server 192.168.20.1
#   LAN machines reach it through the router (192.168.10.x -> 192.168.20.30), and it may answer/initiate towards the LAN. It has NO route to the internet.
#   VMS must be re-addressed once (it still believes 192.168.1.30): see the text printed by `install`.
#
# Safe handling: shut VMS down first (@SYS$SYSTEM:SHUTDOWN on the console) and only then `systemctl stop vax`; a plain stop is a power cut for the emulated machine.
# The disk images are copies. Do not keep using the Pi's VAX and this one in parallel unless you accept two diverging systems.
# Options (environment): VAX_IP=192.168.20.30  VAX_GW=192.168.20.1  IMPORT=~/cmpi-import  ASSUME_YES=1  DRY_RUN=1
set -euo pipefail

VAX_GW="${VAX_GW:-192.168.20.1}"; VAX_IP="${VAX_IP:-192.168.20.30}"
DRY_RUN="${DRY_RUN:-0}"; ASSUME_YES="${ASSUME_YES:-0}"
RUN_USER="${SUDO_USER:-$USER}"; RUN_HOME=$(getent passwd "$RUN_USER" | cut -d: -f6)
IMPORT="${IMPORT:-$RUN_HOME/cmpi-import}"
BUILD_DIR="${BUILD_DIR:-$RUN_HOME/simh-build}"
VAX_HOME=/var/simh/vax
CONSOLE_PORT=2323
export DEBIAN_FRONTEND=noninteractive

die(){ echo "ERROR: $*" >&2; exit 1; }
say(){ printf '\n==> %s\n' "$*"; }
case "${1:-}" in
  deps|install|check) [[ $DRY_RUN == 1 || $EUID -eq 0 ]] || die "run as root (sudo)" ;;
  build) [[ $EUID -ne 0 ]] || die "run 'build' as your normal user (no root needed to compile)" ;;
esac
[[ $VAX_GW =~ ^192\.168\.[0-9]+\.1$ && $VAX_IP =~ ^192\.168\.[0-9]+\.[0-9]+$ ]] || die "VAX_GW must look like 192.168.N.1 and VAX_IP like 192.168.N.x"
VAX_NET="${VAX_GW%.1}.0/24"

BK=${BACKUP_ROOT:-/root}/vax-setup-backup-$(date +%Y%m%d-%H%M%S)
bk(){ [[ -e $1 ]] || return 0; mkdir -p "$BK"; cp -a --parents "$1" "$BK"; }
run(){ if [[ $DRY_RUN == 1 ]]; then printf '+ %s\n' "$*"; else "$@"; fi; }
put(){
  local path=$1 mode=$2 own=${3:-root:root} t
  if [[ $DRY_RUN == 1 ]]; then printf '+ write %s (mode %s, %s):\n' "$path" "$mode" "$own"; sed 's/^/    | /'; return 0; fi
  bk "$path"; install -d "$(dirname "$path")"
  t=$(mktemp "$path.XXXXXX"); cat > "$t"; chmod "$mode" "$t"; chown "$own" "$t"; mv "$t" "$path"
}
confirm(){ [[ $ASSUME_YES == 1 || $DRY_RUN == 1 ]] && return 0; local a; read -rp "$1 [y/N] " a; [[ $a == y || $a == Y ]] || die "aborted"; }

# ------------------------------------------------------------------ deps
mode_deps(){
  run apt-get update
  run apt-get install -y build-essential libpcap-dev zlib1g-dev curl ca-certificates rsync
}

# ------------------------------------------------------------------ build
mode_build(){
  command -v gcc >/dev/null && command -v make >/dev/null || die "gcc/make missing: run 'sudo ./bin/setup-vax.sh deps' first"
  [[ -e /usr/include/pcap/pcap.h ]] || die "libpcap-dev missing: run 'sudo ./bin/setup-vax.sh deps' first"
  mkdir -p "$BUILD_DIR"; cd "$BUILD_DIR"
  local sha
  sha=$(curl -fsSL https://api.github.com/repos/open-simh/simh/commits/master | sed -n 's/^  "sha": "\([0-9a-f]\{40\}\)".*/\1/p' | head -1)
  [[ $sha =~ ^[0-9a-f]{40}$ ]] || die "could not read the current open-simh commit from GitHub"
  echo "open-simh commit $sha"
  if [[ ! -x src-$sha/BIN/vax ]]; then
    rm -rf "src-$sha"; mkdir "src-$sha"
    curl -fsSL "https://github.com/open-simh/simh/archive/$sha.tar.gz" | tar xz --strip-components=1 -C "src-$sha"
    ( cd "src-$sha" && make -j"$(nproc)" vax )
  fi
  [[ -x src-$sha/BIN/vax ]] || die "build produced no BIN/vax"
  ln -sfn "src-$sha/BIN/vax" "$BUILD_DIR/vax"; echo "$sha" > "$BUILD_DIR/COMMIT"
  echo "built: $BUILD_DIR/vax"; echo exit | "$BUILD_DIR/vax" 2>&1 | head -4
  echo "network support compiled in:"; echo "show network" | "$BUILD_DIR/vax" 2>&1 | head -12 || true
}

# ------------------------------------------------------------------ install
mode_install(){
  [[ -x $BUILD_DIR/vax ]] || die "no $BUILD_DIR/vax: run './bin/setup-vax.sh build' first"
  [[ -f $IMPORT/vax/media/d0.dsk && -f $IMPORT/vax/vax.ini-prod ]] || die "copy incomplete: $IMPORT/vax/media/d0.dsk or vax.ini-prod missing"
  # an rsync still writing a disk image leaves a hidden temp file next to it
  if compgen -G "$IMPORT/vax/media/.*.dsk.*" >/dev/null && [[ $DRY_RUN != 1 ]]; then die "a disk image is still being copied ($IMPORT/vax/media/.*.dsk.*): wait for it"; fi
  echo "Installs: /usr/local/bin/simh-vax, /var/simh/vax (copy of $IMPORT/vax, ~$(du -sh "$IMPORT/vax" 2>/dev/null | cut -f1)), tap vaxtap $VAX_GW/24, firewall zone, vax.service (NOT enabled)."
  confirm "Continue?"

  say "simulator binary and user"
  run install -m 755 "$BUILD_DIR/vax" /usr/local/bin/simh-vax
  if id simh >/dev/null 2>&1; then echo "user simh exists"; else run useradd --system --home-dir /var/simh --shell /usr/sbin/nologin simh; fi

  say "files"
  run install -d -m 750 -o simh -g simh /var/simh "$VAX_HOME"
  # the install CDs (*.iso) stay in the import folder; the boot CD image OpenVMS_VAX_73.img is copied when complete (no hidden rsync temp files)
  run rsync -aHS --exclude='*.iso' --exclude='.*.??????' "$IMPORT/vax/" "$VAX_HOME/"
  run chown -R simh:simh "$VAX_HOME"
  run chmod -R go-w "$VAX_HOME"
  # vax.ini: the Pi's file with the network line switched to the tap and a telnet console on loopback-only firewalling
  local ini=$IMPORT/vax/vax.ini-prod; local -a cd_sed=()
  if [[ ! -f $IMPORT/vax/media/OpenVMS_VAX_73.img ]]; then
    cd_sed=(-e 's#^attach -r rq3#;attach -r rq3#'); echo "NOTE: OpenVMS_VAX_73.img (the rq3 CD) was not copied, its attach line is commented out"
  fi
  if [[ $DRY_RUN == 1 ]]; then echo "+ derive $VAX_HOME/vax.ini from $ini: attach xq tap:vaxtap, console telnet=$CONSOLE_PORT"
  else
    cp -p "$VAX_HOME/vax.ini-prod" "$VAX_HOME/vax.ini-pi" 2>/dev/null || true
    # The console is BUFFERED: without it simh waits 30 s at boot for a telnet client and then EXITS, so a VAX
    # started with nobody attached (from the web terminal, VAX/simh/ondemand) dies at once.  Keep that line.
    sed -e 's#^attach xq eth0#attach xq tap:vaxtap#' \
        -e "s#^SET CONSOLE BRK=0#SET CONSOLE BRK=0\nSET CONSOLE TELNET=$CONSOLE_PORT\nSET CONSOLE TELNET=BUFFERED=65536#" \
        "${cd_sed[@]}" "$ini" > "$VAX_HOME/vax.ini.new"
    grep -q 'tap:vaxtap' "$VAX_HOME/vax.ini.new" || die "did not find 'attach xq eth0' in the Pi's vax.ini-prod"
    rm -f "$VAX_HOME/vax.ini"; mv "$VAX_HOME/vax.ini.new" "$VAX_HOME/vax.ini"; chown simh:simh "$VAX_HOME/vax.ini"
  fi

  say "tap interface vaxtap (owned by simh, persistent, routed subnet $VAX_NET)"
  put /etc/systemd/network/30-vaxtap.netdev 644 <<EOF
[NetDev]
Name=vaxtap
Kind=tap
[Tap]
User=simh
Group=simh
EOF
  put /etc/systemd/network/30-vaxtap.network 644 <<EOF
[Match]
Name=vaxtap
[Network]
Address=$VAX_GW/24
ConfigureWithoutCarrier=yes
IPv6AcceptRA=no
LinkLocalAddressing=no
EOF
  put /etc/dnsmasq.d/vax.conf 644 <<EOF
# written by setup-vax.sh: answer DNS for the VAX on vaxtap, but give it no DHCP (fixed address in TCPware)
interface=vaxtap
no-dhcp-interface=vaxtap
EOF
  run install -d /etc/router-setup
  if [[ $DRY_RUN == 1 ]]; then echo "+ touch /etc/router-setup/vax-zone"; else date > /etc/router-setup/vax-zone; fi
  run networkctl reload
  run networkctl reconfigure vaxtap || true

  say "unit (manual start; never enabled)"
  put /etc/systemd/system/vax.service 644 <<EOF
[Unit]
Description=simh MicroVAX 3900 (OpenVMS cpvax) - MANUAL START ONLY
After=systemd-networkd.service
Requires=sys-subsystem-net-devices-vaxtap.device
After=sys-subsystem-net-devices-vaxtap.device
[Service]
User=simh
Group=simh
WorkingDirectory=$VAX_HOME
ExecStart=/usr/local/bin/simh-vax $VAX_HOME/vax.ini
StandardInput=null
KillSignal=SIGTERM
TimeoutStopSec=30
Restart=no
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=$VAX_HOME
ProtectHome=yes
PrivateTmp=yes
# Deliberately no [Install] section: it cannot be enabled, so it never starts at boot.
EOF
  run systemctl daemon-reload
  run systemctl restart dnsmasq
  local sr; sr="$(dirname "$(readlink -f "$0")")/setup-router.sh"
  if [[ $DRY_RUN == 1 ]]; then echo "+ $sr fw"; else "$sr" fw; fi

  cat <<EOF

Installed. Start it:   sudo systemctl start vax        Console:   telnet 127.0.0.1 $CONSOLE_PORT   (on cpbee)
Stop it (after VMS SHUTDOWN):   sudo systemctl stop vax

FIRST BOOT - re-address VMS (it still has 192.168.1.30). On the VMS console, as SYSTEM:
  1. Note the interface and current setup:  \$ TCPWARE SHOW INTERFACE   (TCPware 6.0, interface is usually XE0 or ZE0)
  2. Run the TCPware network configuration (\$ @TCPWARE:CNFNET) and set:  address $VAX_IP   netmask 255.255.255.0   gateway $VAX_GW   name server $VAX_GW
  3. \$ @TCPWARE:STOP / @TCPWARE:START  (or reboot), then test:  \$ PING $VAX_GW
From a LAN machine afterwards:  ping $VAX_IP ; telnet $VAX_IP ; ftp $VAX_IP   (add cpvax $VAX_IP to the Windows hosts files / dnsmasq)
EOF
}

mode_check(){
  local bad=0; ok(){ printf '[ ok ] %s\n' "$*"; }; no(){ printf '[FAIL] %s\n' "$*"; bad=1; }
  [[ -x /usr/local/bin/simh-vax ]] && ok "simulator: $(echo exit | /usr/local/bin/simh-vax 2>&1 | grep -m1 -i 'simulator\|vax')" || no "no /usr/local/bin/simh-vax"
  [[ -f $VAX_HOME/media/d0.dsk && -f $VAX_HOME/vax.ini ]] && ok "files in $VAX_HOME ($(du -sh $VAX_HOME | cut -f1))" || no "files missing in $VAX_HOME"
  ip -br addr show vaxtap 2>/dev/null | grep -q "$VAX_GW" && ok "vaxtap $VAX_GW" || no "vaxtap missing"
  [[ $(systemctl is-enabled vax 2>&1 | head -1) != enabled ]] && ok "vax.service is not enabled (manual start) - $(systemctl is-active vax)" || no "vax.service is ENABLED"
  local rules; rules=$(nft list ruleset 2>/dev/null || true)   # not `| grep -q`: with pipefail the early grep exit makes nft fail
  grep -q vaxtap <<<"$rules" && ok "firewall zone loaded ($(grep -c vaxtap <<<"$rules") rules)" || no "no vaxtap rules in the live firewall"
  echo "   media: $(cd $VAX_HOME/media 2>/dev/null && ls -l --block-size=1 d0.dsk d1.dsk OpenVMS_VAX_73.img 2>&1 | awk '{printf "%s=%s ", $NF, $5}')"
  echo "   on-disk: $(du -sh $VAX_HOME | cut -f1) (smaller than the sum of the images because they are copied sparse)"
  if systemctl is-active --quiet vax; then ss -ltnH | awk '$4 ~ /:'"$CONSOLE_PORT"'$/ {print "   console listens on " $4}'; ping -c1 -W2 "$VAX_IP" >/dev/null 2>&1 && ok "VAX answers ping at $VAX_IP" || echo "   (VAX not answering ping yet: VMS may still be booting or not re-addressed)"; fi
  return $bad
}

case "${1:-}" in
  deps) mode_deps;; build) mode_build;; install) mode_install;; check) mode_check;;
  *) sed -n '2,12p' "$0"; exit 1;;
esac
