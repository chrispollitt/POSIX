#!/usr/bin/env bash
# Back up the key bits of cpbee. Two steps: stage on cpbee (root), then pull to OneDrive (from cmlaptop).
#
#   sudo ./bin/backup-cpbee.sh stage      build /var/backups/cpbee/<stamp>/ on cpbee (asks for the archive passphrase, twice, hidden)
#   ./bin/backup-cpbee.sh pull            (on cmlaptop) copy the newest staged set into C:/Users/chris/OneDrive/DB/cpbee/<stamp>/
#   ./bin/backup-cpbee.sh decrypt <file.enc> [dir]   decrypt + unpack an encrypted archive (asks for the passphrase)
#
# What goes where
#   plain (no secrets):  config-*.tgz (nftables, networkd, dnsmasq, apache/postfix/nginx/webmin configs, systemd units, router-setup, public certs, ...),
#                        sysinfo/ (package list, interfaces, ruleset, enabled units, partitions), traffic.db.gz (graph history), RESTORE.txt
#   encrypted:           secrets.tgz.enc  (TLS private keys, relay passwords, LibreNMS .env, Wi-Fi passphrase, ssh host + user keys, snmpd.conf)
#                        pi-data.tgz.enc  (the Pi copy: home dirs, www, root export, /usr/local, etc-extra; built once, reused; PI_DATA=1 rebuilds)
#   NOT included:        VAX disk images (/var/simh), LibreNMS database + RRD, the ISOs, ~/cmpi-import/vax (ask if wanted)
# Encryption: openssl enc -aes-256-cbc -pbkdf2 -iter 600000 (passphrase only in memory, passed by environment variable to one openssl process at a time).
# Options (environment): STAGE_ROOT=/var/backups/cpbee  KEEP=3  PI_DATA=1  ONEDRIVE_DIR=/c/Users/chris/OneDrive/DB/cpbee  SRC=chris@cpbee123  DRY_RUN=1
set -euo pipefail

STAGE_ROOT="${STAGE_ROOT:-/var/backups/cpbee}"
KEEP="${KEEP:-3}"
DRY_RUN="${DRY_RUN:-0}"
ONEDRIVE_DIR="${ONEDRIVE_DIR:-/c/Users/chris/OneDrive/DB/cpbee}"
SRC="${SRC:-chris@cpbee123}"
ENC=(openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt)
die(){ echo "ERROR: $*" >&2; exit 1; }
say(){ printf '\n==> %s\n' "$*"; }

ask_pass(){   # sets BKPASS (hidden, confirmed)
  [[ -t 0 ]] || die "needs a terminal to ask for the passphrase"
  local a b; read -rsp "Archive passphrase: " a; echo; read -rsp "Again: " b; echo
  [[ -n $a && $a == "$b" ]] || die "passphrases are empty or differ"
  [[ ${#a} -ge 8 ]] || die "use at least 8 characters (you will paste it from a password manager)"
  BKPASS=$a
}
encrypt_stream(){ BKPASS="$BKPASS" "${ENC[@]}" -pass env:BKPASS; }   # stdin -> stdout
check_enc(){ [[ $(head -c 8 "$1" 2>/dev/null) == "Salted__" && $(stat -c %s "$1") -gt 64 ]] || { rm -f "$1"; die "encryption failed for $1"; }; }

# ------------------------------------------------------------------ stage (root, on cpbee)
mode_stage(){
  [[ $DRY_RUN == 1 || $EUID -eq 0 ]] || die "run as root (sudo)"
  local owner=${SUDO_USER:-chris} home; home=$(getent passwd "$owner" | cut -d: -f6)
  local stamp dir; stamp=$(date +%Y%m%d-%H%M%S); dir=$STAGE_ROOT/$stamp
  say "staging in $dir"
  if [[ $DRY_RUN != 1 ]]; then
    install -d -m 755 "$STAGE_ROOT"; install -d -m 750 -o "$owner" -g "$owner" "$dir"; mkdir -p "$dir/sysinfo"; chown "$owner:$owner" "$dir/sysinfo"
  fi
  [[ $DRY_RUN == 1 ]] || ask_pass

  say "configuration (plain, secrets excluded)"
  local -a paths=() p
  for p in etc/nftables.conf etc/systemd/network etc/systemd/system etc/dnsmasq.d etc/sysctl.d etc/router-setup etc/hosts etc/hostname etc/fstab etc/default/grub \
           etc/apache2 etc/postfix etc/nginx/conf.d etc/php/8.4/fpm/pool.d etc/mysql/mariadb.conf.d etc/ssh/sshd_config.d etc/webmin etc/trafficgraph/config.json \
           etc/vsftpd.conf etc/cron.d etc/apt/sources.list.d etc/ssl/Simple_Inc/certs etc/aliases etc/mailname etc/lldpd.d etc/librenms etc/logrotate.d/librenms \
           etc/cron.d/librenms etc/bash_completion.d/lnms-completion.bash opt/librenms/config.d opt/librenms/config.php; do
    [[ -e /$p ]] && paths+=("$p")
  done
  if [[ $DRY_RUN == 1 ]]; then printf '+ tar czf config-%s.tgz (%d paths; excluded: private keys, sasl_passwd*, smtp-password, wpa_supplicant, miniserv.pem)\n' "$stamp" "${#paths[@]}"
  else
    tar czf "$dir/config-$stamp.tgz" --ignore-failed-read \
      --exclude='etc/postfix/sasl_passwd*' --exclude='etc/trafficgraph/smtp-password' --exclude='etc/ssl/Simple_Inc/certs/*.key' \
      --exclude='etc/webmin/miniserv.pem' --exclude='etc/postfix/*.db' -C / "${paths[@]}" 2>/dev/null || true
    echo "  $(du -h "$dir/config-$stamp.tgz" | cut -f1) $(tar tzf "$dir/config-$stamp.tgz" | wc -l) entries"
  fi

  say "system information"
  if [[ $DRY_RUN == 1 ]]; then echo "+ dpkg selections, manual packages, ip addr/route, nft ruleset, enabled units, lsblk, efibootmgr, versions -> sysinfo/"
  else
    local s=$dir/sysinfo
    dpkg --get-selections > "$s/dpkg-selections.txt"; apt-mark showmanual > "$s/apt-manual.txt"
    { ip -br addr; echo; ip route; echo; ip -br link; } > "$s/network.txt" 2>&1
    nft list ruleset > "$s/nft-ruleset.txt" 2>&1 || true
    systemctl list-unit-files --state=enabled --no-legend > "$s/enabled-units.txt" 2>&1 || true
    { lsblk -f; echo; efibootmgr -v 2>&1; echo; df -h; } > "$s/disks.txt" 2>&1 || true
    { uname -a; cat /etc/os-release; } > "$s/system.txt"
    { echo "simh: $(cat /home/$owner/simh-build/COMMIT 2>/dev/null || echo unknown)"; /usr/local/bin/simh-vax </dev/null 2>&1 | head -2 || true; } > "$s/versions.txt" 2>&1 || true
    chown -R "$owner:$owner" "$s"
  fi

  say "traffic-graph database (consistent copy)"
  if [[ -f /var/lib/trafficgraph/traffic.db ]]; then
    if [[ $DRY_RUN == 1 ]]; then echo "+ sqlite online backup of /var/lib/trafficgraph/traffic.db -> traffic.db.gz"
    else
      python3 - "$dir/traffic.db" <<'PY'
import sqlite3, sys
src = sqlite3.connect("file:/var/lib/trafficgraph/traffic.db?mode=ro", uri=True)
dst = sqlite3.connect(sys.argv[1]); src.backup(dst); dst.close(); src.close()
PY
      gzip -f "$dir/traffic.db"; echo "  $(du -h "$dir/traffic.db.gz" | cut -f1)"
    fi
  else echo "(no /var/lib/trafficgraph/traffic.db)"; fi

  say "secrets (encrypted)"
  local -a sec=()
  for p in etc/ssl/Simple_Inc/certs/*.key etc/postfix/sasl_passwd etc/trafficgraph/smtp-password opt/librenms/.env etc/wpa_supplicant etc/snmp/snmpd.conf \
           etc/ssh/ssh_host_* etc/webmin/miniserv.pem "home/$owner/.ssh" "home/$owner/cmpi-import/secrets"; do
    for f in /$p; do [[ -e $f ]] && sec+=("${f#/}"); done
  done
  if [[ $DRY_RUN == 1 ]]; then printf '+ tar | openssl -> secrets.tgz.enc (%d items)\n' "${#sec[@]}"; printf '    %s\n' "${sec[@]}"
  else
    ( set +o pipefail; tar czf - --ignore-failed-read -C / "${sec[@]}" 2>/dev/null | encrypt_stream > "$dir/secrets.tgz.enc" )
    check_enc "$dir/secrets.tgz.enc"
    echo "  $(du -h "$dir/secrets.tgz.enc" | cut -f1)"
  fi

  say "Pi data copy (encrypted, built once)"
  local pidata=$STAGE_ROOT/pi-data.tgz.enc
  local -a pisrc=()
  for p in "home/$owner/cmpi-import/home" "home/$owner/cmpi-import/www" "home/$owner/cmpi-import/root" "home/$owner/cmpi-import/etc-extra" "home/$owner/cmpi-import/usr-local" root/cmpi-import/root; do
    [[ -e /$p ]] && pisrc+=("$p")
  done
  if [[ -e $pidata && ${PI_DATA:-0} != 1 ]]; then echo "  $pidata exists ($(du -h "$pidata" | cut -f1)): keeping it (PI_DATA=1 rebuilds)"
  elif [[ $DRY_RUN == 1 ]]; then echo "+ tar czf - ${pisrc[*]} | openssl -> $pidata"; du -shc "${pisrc[@]/#//}" 2>/dev/null | tail -1
  else
    echo "  packing ${#pisrc[@]} folders (a few minutes)..."
    ( set +o pipefail; tar czf - --ignore-failed-read -C / "${pisrc[@]}" 2>/dev/null | encrypt_stream > "$pidata.part" )
    check_enc "$pidata.part" && mv "$pidata.part" "$pidata"
    chown "$owner:$owner" "$pidata"; echo "  $(du -h "$pidata" | cut -f1)"
  fi
  unset BKPASS

  if [[ $DRY_RUN != 1 ]]; then
    cat > "$dir/RESTORE.txt" <<EOF
cpbee backup $stamp
  config-*.tgz       plain: tar xzf config-*.tgz -C /   (review first: it overwrites /etc files)
  sysinfo/           what was installed and running
  traffic.db.gz      traffic-graph history (gunzip -> /var/lib/trafficgraph/traffic.db, service stopped)
  secrets.tgz.enc    encrypted: ./bin/backup-cpbee.sh decrypt secrets.tgz.enc  (or: openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -in secrets.tgz.enc | tar xz -C /)
  ../pi-data/pi-data.tgz.enc   encrypted copy of the Pi's home dirs, www, root export, /usr/local
Rebuild order: Debian 13 + dual boot (prepare-dualboot.ps1), restore the repo cmpi-router from OneDrive, run setup-router.sh (modes), setup-services.sh, setup-monitoring.sh, setup-vax.sh,
restore config, then secrets. The VAX disk images are NOT in this backup (copy from the Pi / /var/simh/vax separately).
EOF
    chown "$owner:$owner" "$dir/RESTORE.txt"; chown -R "$owner:$owner" "$dir"; chmod 640 "$dir"/*.enc 2>/dev/null || true
    ln -sfn "$dir" "$STAGE_ROOT/latest"
    # keep the newest $KEEP staged sets
    ls -1d "$STAGE_ROOT"/2* 2>/dev/null | head -n -"$KEEP" | xargs -r rm -rf
    say "staged"; ls -lh "$dir" "$pidata" 2>/dev/null
    echo; echo "Next, on cmlaptop:  ./bin/backup-cpbee.sh pull"
  fi
}

# ------------------------------------------------------------------ pull (cmlaptop)
mode_pull(){
  [[ -d $(dirname "$ONEDRIVE_DIR") ]] || die "OneDrive folder $(dirname "$ONEDRIVE_DIR") not found (set ONEDRIVE_DIR)"
  mkdir -p "$ONEDRIVE_DIR" "$ONEDRIVE_DIR/pi-data"
  local stamp; stamp=$(ssh "$SRC" 'basename "$(readlink -f '"$STAGE_ROOT"'/latest)"') || die "cannot reach $SRC or no staged backup"
  [[ $stamp =~ ^[0-9]{8}-[0-9]{6}$ ]] || die "unexpected staged name '$stamp'"
  say "copying $stamp to $ONEDRIVE_DIR/$stamp"
  mkdir -p "$ONEDRIVE_DIR/$stamp"
  scp -qr "$SRC:$STAGE_ROOT/$stamp/." "$ONEDRIVE_DIR/$stamp/"
  local rsize lsize
  rsize=$(ssh "$SRC" "stat -c %s $STAGE_ROOT/pi-data.tgz.enc 2>/dev/null || echo 0")
  lsize=$(stat -c %s "$ONEDRIVE_DIR/pi-data/pi-data.tgz.enc" 2>/dev/null || echo 0)
  if [[ $rsize -gt 0 && $rsize != "$lsize" ]]; then say "Pi data copy ($((rsize/1048576)) MB)"; scp -q "$SRC:$STAGE_ROOT/pi-data.tgz.enc" "$ONEDRIVE_DIR/pi-data/pi-data.tgz.enc"
  else echo "Pi data copy unchanged: not copied again"; fi
  ls -1d "$ONEDRIVE_DIR"/2* 2>/dev/null | head -n -"$KEEP" | xargs -r rm -rf
  say "done"; ls -lh "$ONEDRIVE_DIR/$stamp"; du -sh "$ONEDRIVE_DIR" | cut -f1
}

# ------------------------------------------------------------------ decrypt
mode_decrypt(){
  local f=${2:-} out=${3:-.}; [[ -f $f ]] || die "usage: $0 decrypt <file.enc> [target-dir]"
  mkdir -p "$out"; read -rsp "Passphrase: " BKPASS; echo
  BKPASS="$BKPASS" openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass env:BKPASS -in "$f" | tar xzf - -C "$out"
  echo "unpacked into $out"
}

case "${1:-}" in
  stage) mode_stage;; pull) mode_pull;; decrypt) mode_decrypt "$@";;
  *) sed -n '2,19p' "$0"; exit 1;;
esac
