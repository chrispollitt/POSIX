#!/bin/bash
# Put the console apps behind nginx on cpbee: https://192.168.10.1:8444/ lists them
# (maze4, bidet, cpvax, cpvax-console).  Safe to run again to pick up changes.
# Run it ON cpbee, as the user that owns ~/gh_cp (it uses sudo for the nginx and firewall parts).
#
#   ./install.sh -n      show what it would do, change nothing
#   ./install.sh         do it (asks first, and asks for the web user's password the first time)
#   ./install.sh -u      take it all out again (units, nginx files; keeps the htpasswd and the firewall entry)
#
# Needs: nginx, openssl, systemd (user units), ~/bin/ttyd, and the run-ttyd.sh launchers in ~/gh_cp:
# Games/maze4/ttyd, CWPutils/BIDeT/4D/ttyd and VAX/simh/ttyd.
# The firewall port goes through ../net-utils/lan-port (cmpi-router's port list), not a hand edit.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
lanport=$here/../net-utils/lan-port
port=8444
conf=/etc/nginx/conf.d/web-ttyd.conf
snip=/etc/nginx/snippets/web-ttyd-proxy.conf
webdir=/usr/share/web-ttyd
pages=(frame.html index.html)
users_file=/etc/nginx/web-ttyd.htpasswd
unitdir=$HOME/.config/systemd/user
apps=(maze4 bidet cpvax cpvax-console)
launchers=("$HOME/gh_cp/Games/maze4/ttyd/run-ttyd.sh" "$HOME/gh_cp/CWPutils/BIDeT/4D/ttyd/run-ttyd.sh"
           "$HOME/gh_cp/VAX/simh/ttyd/run-ttyd.sh")

dry=0 undo=0
while getopts nu opt; do
  case $opt in n) dry=1 ;; u) undo=1 ;; *) echo "usage: $0 [-n|-u]" >&2; exit 2 ;; esac
done

say() { printf '%s\n' "$*"; }
run() { if (( dry )); then say "  would run: $*"; else "$@"; fi; }

if (( undo )); then
  say "Removing the web-ttyd units and nginx files (kept: $users_file, and port $port in the firewall list:"
  say "  take that out with: $lanport remove $port)."
  for a in "${apps[@]}"; do
    run systemctl --user disable --now "web-ttyd-$a.service" || true
    run rm -f "$unitdir/web-ttyd-$a.service"
  done
  run systemctl --user daemon-reload
  for p in "${pages[@]}"; do run sudo rm -f "$webdir/$p"; done
  run sudo rm -f "$conf" "$snip"
  run sudo rmdir "$webdir" || true
  (( dry )) || { sudo nginx -t && sudo systemctl reload nginx; }
  exit 0
fi

# --- checks, before anything changes ---
[ -x "$HOME/bin/ttyd" ] || { echo "no ~/bin/ttyd" >&2; exit 1; }
for l in "${launchers[@]}"; do [ -x "$l" ] || { echo "missing or not executable: $l" >&2; exit 1; }; done
[ -x "$lanport" ] || { echo "missing or not executable: $lanport" >&2; exit 1; }
[ -x /usr/sbin/nginx ] || command -v nginx >/dev/null || { echo "nginx not found" >&2; exit 1; }
command -v openssl >/dev/null || { echo "openssl not found" >&2; exit 1; }
command -v telnet >/dev/null && command -v nc >/dev/null || { echo "cpvax needs telnet and nc" >&2; exit 1; }
[ -f /etc/nginx/snippets/cpbee-tls.conf ] || { echo "no /etc/nginx/snippets/cpbee-tls.conf" >&2; exit 1; }
# in use by something else (on a re-run it is our own nginx)
if [ ! -e "$conf" ] && ss -ltn 2>/dev/null | grep "192.168.10.1:$port " >/dev/null; then
  echo "192.168.10.1:$port is already in use" >&2; exit 1
fi

say "This will:"
say "  1. stop any hand-started ttyd of yours, then (re)start the systemd user units web-ttyd-{${apps[*]// /,}}"
say "     and enable lingering so they survive logout and reboot"
say "  2. create $users_file if there is none (you type the user name and password)"
say "  3. install $conf, $snip and the pages in $webdir, test nginx, reload it"
say "  4. list $port in the firewall's LAN port list and reload the firewall (lan-port add)"
if (( ! dry )); then
  read -r -p "Proceed? [y/N] " ans
  [[ $ans == [yY]* ]] || { say "Nothing changed."; exit 1; }
fi

# --- the password file, only if there is none yet ---
if sudo test -e "$users_file"; then
  say "$users_file exists: keeping it (add users with: sudo sh -c 'printf \"%s:%s\\n\" NAME \"\$(openssl passwd -apr1)\" >> $users_file')"
elif (( dry )); then
  say "  would ask for a user name and password and create $users_file (root:www-data, 640)"
else
  read -r -p "Web user name: " wuser
  [[ $wuser =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "user name: letters, digits, _ . - only" >&2; exit 1; }
  hash=$(openssl passwd -apr1)
  [ -n "$hash" ] || { echo "no password hash" >&2; exit 1; }
  printf '%s:%s\n' "$wuser" "$hash" | sudo tee "$users_file" >/dev/null
  sudo chown root:www-data "$users_file"
  sudo chmod 640 "$users_file"
fi

# --- nginx: install, test, reload; put the previous files back (or remove the new ones) if the test fails ---
bak=$(mktemp -d); trap 'rm -rf "$bak"' EXIT
mine=("$conf" "$snip"); for p in "${pages[@]}"; do mine+=("$webdir/$p"); done
if (( ! dry )); then
  for f in "${mine[@]}"; do if [ -e "$f" ]; then sudo cp -p "$f" "$bak/$(basename "$f")"; fi; done
fi
for p in "${pages[@]}"; do run sudo install -D -m 644 "$here/$p" "$webdir/$p"; done
run sudo install -m 644 "$here/web-ttyd-proxy.conf" "$snip"
run sudo install -m 644 "$here/web-ttyd.conf" "$conf"
if (( ! dry )); then
  if ! sudo nginx -t; then
    for f in "${mine[@]}"; do
      if [ -e "$bak/$(basename "$f")" ]; then sudo cp -p "$bak/$(basename "$f")" "$f"; else sudo rm -f "$f"; fi
    done
    echo "nginx -t failed: put the previous files back (or removed the new ones); nginx was not reloaded" >&2
    exit 1
  fi
  sudo systemctl reload nginx
fi

# --- the firewall: through the shared helper, so cmpi-router's list stays the one source of truth ---
if (( dry )); then LAN_PORT_DRY=1 "$lanport" add "$port" "web-ttyd https (nginx)" || true
else "$lanport" add "$port" "web-ttyd https (nginx)" || echo "firewall: not done - see above; the apps are up but the LAN cannot reach port $port yet" >&2
fi

# --- the ttyd services ---
run pkill -u "$USER" -x ttyd || true
run mkdir -p "$unitdir"
for a in "${apps[@]}"; do
  run install -m 644 "$here/web-ttyd-$a.service" "$unitdir/web-ttyd-$a.service"
done
run systemctl --user daemon-reload
for a in "${apps[@]}"; do
  run systemctl --user enable "web-ttyd-$a.service"
  run systemctl --user restart "web-ttyd-$a.service"
done
run sudo loginctl enable-linger "$USER"

say "Done.  https://192.168.10.1:$port/   status: systemctl --user status 'web-ttyd-*'   check: $lanport check"
