#!/usr/bin/env bash
# The Android phone as the WAN (FINAL): read its byte counters over adb and show them as cards in the traffic graphs
# (Phone: cellular / tethered / Wi-Fi hotspot) and, optionally, use the phone's cellular counter for the data-plan meter.
#
#   SERIAL=<adb serial> sudo -E ./bin/setup-phone.sh install   adb server as a locked-down systemd service + config + restart of the graphs
#   sudo ./bin/setup-phone.sh check                            service, socket permissions, phone authorisation, what the graphs see
#   sudo ./bin/setup-phone.sh meter phone|wan                  plan meter source: the phone's cellular counter (what the carrier counts) or wan0
#   sudo ./bin/setup-phone.sh off                              stop it all and hide the cards (keeps the user, the key and the package)
#
# Find the serial with:  adb devices   (while the phone is attached and authorised), or  lsusb -v 2>/dev/null | grep -A2 Pixel | grep iSerial
# Options (environment): SERIAL=...  DRY_RUN=1 (print only, works without root)  ASSUME_YES=1  PHONE_USER=adbphone
#
# Design: only the `adbphone` service user can open the phone (udev rule by serial) and only adbphone + the graphs service can open
# the adb server's Unix socket (/run/adbphone/server.sock, group adbphone). Nothing else on the router (PHP, nginx, LibreNMS) can get a
# shell on the phone. The graphs speak the adb protocol themselves and only ever run three fixed read-only commands (traffic/phone.py).
# The phone must be authorised ONCE for the service's own key (a prompt on the phone: "Always allow"). Authorised USB debugging means a
# compromised cpbee could open a shell on the phone: keep ssh to cpbee key-only (it is) and the phone screen locked.
set -euo pipefail

DRY_RUN="${DRY_RUN:-0}"
ASSUME_YES="${ASSUME_YES:-0}"
PHONE_USER="${PHONE_USER:-adbphone}"
SERIAL_FILE=/etc/router-setup/phone-serial
CONF=/etc/trafficgraph/config.json
UNIT=/etc/systemd/system/adb-phone.service
DROPIN_DIR=/etc/systemd/system/trafficgraph.service.d
DROPIN=$DROPIN_DIR/phone.conf
UDEV=/etc/udev/rules.d/70-adbphone.rules
SOCK=/run/adbphone/server.sock
STATE=/var/lib/adbphone

die(){ echo "ERROR: $*" >&2; exit 1; }
say(){ printf '\n==> %s\n' "$*"; }
run(){ if [[ $DRY_RUN == 1 ]]; then printf '+ %s\n' "$*"; else "$@"; fi; }
confirm(){ [[ $ASSUME_YES == 1 || $DRY_RUN == 1 ]] && return 0; local a; read -rp "$1 [y/N] " a; [[ $a == y || $a == Y ]] || die "aborted"; }
BK=${BACKUP_ROOT:-/root}/phone-setup-backup-$(date +%Y%m%d-%H%M%S)
bk(){ [[ -e $1 ]] || return 0; mkdir -p "$BK"; cp -a --parents "$1" "$BK"; }
put(){   # put <path> <mode>   (content on stdin; the old file is saved in $BK)
  local path=$1 mode=$2
  if [[ $DRY_RUN == 1 ]]; then printf '+ write %s (mode %s):\n' "$path" "$mode"; sed 's/^/    | /'; return 0; fi
  bk "$path"; install -d "$(dirname "$path")"; cat > "$path"; chmod "$mode" "$path"
}

case "${1:-}" in
  install|check|meter|off) [[ $DRY_RUN == 1 || $EUID -eq 0 ]] || die "run as root (sudo)" ;;
  *) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac

# edit /etc/trafficgraph/config.json: setcfg phone.enabled=true  or  setcfg cap_iface=phone-cell (values are JSON)
setcfg(){
  if [[ $DRY_RUN == 1 ]]; then echo "+ set $* in $CONF"; return 0; fi
  bk "$CONF"
  python3 - "$CONF" "$@" <<'PY'
import json, sys
path, *pairs = sys.argv[1:]
try:
    cfg = json.load(open(path))
except FileNotFoundError:
    cfg = {}
for p in pairs:
    key, _, raw = p.partition("=")
    try:
        val = json.loads(raw)
    except ValueError:
        val = raw
    node = cfg
    *parents, last = key.split(".")
    for k in parents:
        node = node.setdefault(k, {})
    node[last] = val
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PY
  chown root:trafficgraph "$CONF" 2>/dev/null || true; chmod 640 "$CONF"
}

api(){ curl -s -m 5 "http://127.0.0.1:8081$1" 2>/dev/null || true; }

serial(){
  local s="${SERIAL:-}"
  [[ -n $s ]] || s=$(cat "$SERIAL_FILE" 2>/dev/null || true)
  [[ -n $s ]] || die "no phone serial: run  SERIAL=<serial> sudo -E $0 install   (find it with 'adb devices')"
  [[ $s =~ ^[A-Za-z0-9._-]{4,64}$ ]] || die "odd-looking serial '$s'"
  echo "$s"
}

adbc(){   # an adb client talking to OUR server socket (root can open it)
  ADB_SERVER_SOCKET=localfilesystem:$SOCK HOME=$STATE timeout "${ADB_TIMEOUT:-10}" adb "$@"
}

# ------------------------------------------------------------------------------------------------ install
if [[ $1 == install ]]; then
  S=$(serial)
  say "installing the adb server for phone $S (user $PHONE_USER, socket $SOCK)"
  confirm "Continue? (an adb server already running as another user will be stopped so this one can claim the phone)"
  command -v adb >/dev/null || run apt-get install -y adb
  command -v python3 >/dev/null || run apt-get install -y python3
  getent group adbphone >/dev/null || run groupadd --system adbphone
  id "$PHONE_USER" >/dev/null 2>&1 || run useradd --system --gid adbphone --no-create-home --home-dir "$STATE" --shell /usr/sbin/nologin "$PHONE_USER"
  run install -d -o "$PHONE_USER" -g adbphone -m 700 "$STATE"
  run install -d -m 755 /etc/router-setup
  if [[ $DRY_RUN == 1 ]]; then echo "+ save the serial to $SERIAL_FILE"; else printf '%s\n' "$S" > "$SERIAL_FILE"; fi

  say "udev: let the service user open exactly this phone (by serial)"
  put "$UDEV" 644 <<EOF
# written by setup-phone.sh: the phone with this serial is opened by the adbphone group only (any USB mode: adb, rndis+adb, ...)
SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{serial}=="$S", GROUP="adbphone", MODE="0660"
EOF
  run udevadm control --reload
  run udevadm trigger --subsystem-match=usb --action=change

  say "systemd: adb server on a Unix socket"
  put "$UNIT" 644 <<EOF
[Unit]
Description=adb server for the phone WAN counters (Unix socket: adbphone + trafficgraph only)
After=local-fs.target

[Service]
User=$PHONE_USER
Group=adbphone
Environment=HOME=$STATE
UMask=0007
RuntimeDirectory=adbphone
RuntimeDirectoryMode=0750
ExecStart=/usr/bin/adb -L localfilesystem:$SOCK --one-device $S server nodaemon
Restart=on-failure
RestartSec=5
# one job: talk to one phone over USB and to the graphs over a socket
NoNewPrivileges=yes
CapabilityBoundingSet=
ProtectSystem=strict
ReadWritePaths=$STATE
ProtectHome=yes
PrivateTmp=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
RestrictNamespaces=yes
LockPersonality=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
IPAddressDeny=any
IPAddressAllow=localhost

[Install]
WantedBy=multi-user.target
EOF
  put "$DROPIN" 644 <<EOF
# written by setup-phone.sh: the graphs service may open the adb socket (group adbphone), nothing else changes
[Service]
SupplementaryGroups=adbphone
EOF

  say "stopping any other adb server (it would hold the phone's USB interface)"
  listen=$(ss -ltn 2>/dev/null || true)
  if [[ $listen == *127.0.0.1:5037* ]]; then
    run bash -c 'HOME=/root adb kill-server || true'
  fi
  pgrep -ax adb 2>/dev/null | grep -v "adb-phone\|--one-device" | sed 's/^/  still running: /' || true

  say "start"
  run systemctl daemon-reload
  run systemctl enable --now adb-phone.service
  if [[ $DRY_RUN != 1 ]]; then
    sleep 3
    systemctl is-active --quiet adb-phone && echo "adb-phone is running" || { echo "adb-phone FAILED:"; journalctl -u adb-phone -n 20 --no-pager; exit 1; }
    ls -l "$SOCK"
    echo "Waiting up to 90 s for the phone (unlock it; accept the 'Allow USB debugging?' prompt and tick 'Always allow from this computer')..."
    st=""
    for _ in $(seq 45); do
      st=$(adbc devices 2>/dev/null | awk -v s="$S" '$1==s{print $2}')
      [[ $st == device ]] && break
      sleep 2
    done
    echo "phone state: ${st:-not seen}  (device = authorised and ready; unauthorized = accept the prompt on the phone; empty = check the cable/serial)"
  fi

  say "graphs: enable the phone cards"
  setcfg 'phone.enabled=true' "phone.serial=\"$S\"" "phone.adb_socket=\"localfilesystem:$SOCK\""
  run systemctl daemon-reload
  run systemctl restart trafficgraph.service
  if [[ $DRY_RUN != 1 ]]; then
    sleep 8
    api /api/config | python3 -c 'import json,sys; p=json.load(sys.stdin)["phone"]; print("graphs see the phone:", p["connected"], p["model"], "| error:", p["error"])' || echo "could not read the graphs API"
  fi
  echo
  echo "Done. Cards: Phone: cellular / tethered / Wi-Fi hotspot (https://cpbee:8443/). Plan meter on the phone's counter: sudo $0 meter phone"
  echo "FINAL reminder: the phone's own Wi-Fi client must be OFF (or the home networks forgotten), or tethering may use that Wi-Fi as its upstream."
  exit 0
fi

# ------------------------------------------------------------------------------------------------ check
if [[ $1 == check ]]; then
  ok(){ printf '  [ ok ] %s\n' "$*"; }; bad(){ printf '  [FAIL] %s\n' "$*"; }; info(){ printf '  [info] %s\n' "$*"; }
  S=$(cat "$SERIAL_FILE" 2>/dev/null || true); [[ -n $S ]] && ok "phone serial saved: $S" || bad "no serial saved ($SERIAL_FILE): run install"
  command -v adb >/dev/null && ok "adb installed ($(adb version 2>/dev/null | sed -n 2p))" || bad "adb not installed"
  id "$PHONE_USER" >/dev/null 2>&1 && ok "user $PHONE_USER exists" || bad "user $PHONE_USER missing"
  [[ -f $UDEV ]] && ok "udev rule present" || bad "udev rule $UDEV missing"
  systemctl is-active --quiet adb-phone && ok "adb-phone service running" || bad "adb-phone service not running"
  if [[ -S $SOCK ]]; then
    perm=$(stat -c '%a %U:%G' "$SOCK"); [[ $perm == "770 $PHONE_USER:adbphone" ]] && ok "socket $SOCK is $perm" || bad "socket permissions are $perm (want 770 $PHONE_USER:adbphone)"
  else bad "socket $SOCK missing"; fi
  grep -q 'SupplementaryGroups=adbphone' "$DROPIN" 2>/dev/null && ok "graphs service may open the socket" || bad "drop-in $DROPIN missing"
  listen=$(ss -ltn 2>/dev/null || true)
  if [[ $listen == *127.0.0.1:5037* ]]; then bad "another adb server listens on 127.0.0.1:5037 (any local user could reach the phone through it): stop it with: adb kill-server"; else ok "no adb server on TCP 5037"; fi
  if [[ -n $S && -S $SOCK ]]; then
    st=$(adbc devices 2>/dev/null | awk -v s="$S" '$1==s{print $2}')
    case "$st" in device) ok "phone authorised and online" ;; unauthorized) bad "phone unauthorized: unlock it and accept the USB debugging prompt (Always allow)" ;; "") bad "phone not seen (cable? serial? USB debugging on?)" ;; *) info "phone state: $st" ;; esac
  fi
  p=$(api /api/config | python3 -c 'import json,sys; p=json.load(sys.stdin).get("phone"); print("old-version" if p is None else "%s %s %s %s %s" % (p["enabled"], p["connected"], p["model"], p["upstream"], p["error"]))' 2>/dev/null || true)
  if [[ -z $p ]]; then bad "graphs API not answering"
  elif [[ $p == old-version ]]; then bad "the installed graphs service predates phone support: run  sudo ./bin/setup-router.sh graphs  first"; p=""
  else info "graphs: enabled connected model upstream error = $p"; fi
  [[ $p == "True True"* ]] && ok "graphs read the phone" || bad "graphs are not reading the phone"
  info "plan meter source: $(python3 -c 'import json; print(json.load(open("'"$CONF"'")).get("cap_iface","wan0"))' 2>/dev/null)"
  exit 0
fi

# ------------------------------------------------------------------------------------------------ meter
if [[ $1 == meter ]]; then
  case "${2:-}" in
    phone) setcfg 'cap_iface="phone-cell"'; echo "plan meter now counts the phone's cellular link (rmnet_ipa0). The config is re-read within seconds." ;;
    wan)   setcfg 'cap_iface="wan0"';       echo "plan meter now counts wan0 (interface counters of the router)." ;;
    *) die "usage: $0 meter phone|wan" ;;
  esac
  exit 0
fi

# ------------------------------------------------------------------------------------------------ off
if [[ $1 == off ]]; then
  confirm "Stop the adb service and hide the phone cards?"
  setcfg 'phone.enabled=false' 'cap_iface="wan0"'
  run systemctl disable --now adb-phone.service
  run rm -f "$DROPIN" "$UDEV"
  run systemctl daemon-reload
  run udevadm control --reload
  run systemctl restart trafficgraph.service
  echo "Off. Kept: user $PHONE_USER, its key in $STATE, the adb package, history in the graphs."
  exit 0
fi
