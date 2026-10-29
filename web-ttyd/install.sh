#!/bin/bash
# Put maze4 and bidet behind nginx on cpbee: https://192.168.10.1:8444/maze4/ and /bidet/
# Run it ON cpbee, as the user that owns ~/gh_cp (it uses sudo for the nginx parts).
#
#   ./install.sh -n      show what it would do, change nothing
#   ./install.sh         do it (asks first, and asks for the web user's password)
#   ./install.sh -u      take it all out again (units, nginx files; keeps the htpasswd)
#
# Needs: nginx, openssl, systemd (user units), ~/bin/ttyd, and the two run-ttyd.sh
# launchers in ~/gh_cp (Games/maze4/ttyd and CWPutils/BIDeT/4D/ttyd).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
conf=/etc/nginx/conf.d/web-ttyd.conf
snip=/etc/nginx/snippets/web-ttyd-proxy.conf
frame=/usr/share/web-ttyd/frame.html
users_file=/etc/nginx/web-ttyd.htpasswd
unitdir=$HOME/.config/systemd/user
apps=(maze4 bidet)
launchers=("$HOME/gh_cp/Games/maze4/ttyd/run-ttyd.sh" "$HOME/gh_cp/CWPutils/BIDeT/4D/ttyd/run-ttyd.sh")

dry=0 undo=0
while getopts nu opt; do
  case $opt in n) dry=1 ;; u) undo=1 ;; *) echo "usage: $0 [-n|-u]" >&2; exit 2 ;; esac
done

say() { printf '%s\n' "$*"; }
run() { if (( dry )); then say "  would run: $*"; else "$@"; fi; }

if (( undo )); then
  say "Removing the web-ttyd units and nginx files (the password file $users_file stays)."
  for a in "${apps[@]}"; do
    run systemctl --user disable --now "web-ttyd-$a.service" || true
    run rm -f "$unitdir/web-ttyd-$a.service"
  done
  run systemctl --user daemon-reload
  run sudo rm -f "$conf" "$snip" "$frame"
  run sudo rmdir /usr/share/web-ttyd || true
  (( dry )) || { sudo nginx -t && sudo systemctl reload nginx; }
  exit 0
fi

# --- checks, before anything changes ---
[ -x "$HOME/bin/ttyd" ] || { echo "no ~/bin/ttyd" >&2; exit 1; }
for l in "${launchers[@]}"; do [ -x "$l" ] || { echo "missing or not executable: $l" >&2; exit 1; }; done
[ -x /usr/sbin/nginx ] || command -v nginx >/dev/null || { echo "nginx not found" >&2; exit 1; }
command -v openssl >/dev/null || { echo "openssl not found" >&2; exit 1; }
[ -f /etc/nginx/snippets/cpbee-tls.conf ] || { echo "no /etc/nginx/snippets/cpbee-tls.conf" >&2; exit 1; }
if ss -ltn 2>/dev/null | grep '192.168.10.1:8444 ' >/dev/null; then echo "192.168.10.1:8444 is already in use" >&2; exit 1; fi

say "This will:"
say "  1. stop any hand-started ttyd of yours, install and start two systemd user units"
say "     (web-ttyd-maze4, web-ttyd-bidet) and enable lingering so they survive logout and reboot"
say "  2. create $users_file (you type the user name and password)"
say "  3. install $conf, $snip and the window frame $frame, test nginx, reload it"
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

# --- nginx: install, test, reload; put things back if the test fails ---
run sudo install -D -m 644 "$here/frame.html" "$frame"
run sudo install -m 644 "$here/web-ttyd-proxy.conf" "$snip"
run sudo install -m 644 "$here/web-ttyd.conf" "$conf"
if (( ! dry )); then
  if ! sudo nginx -t; then
    sudo rm -f "$conf" "$snip" "$frame"
    echo "nginx -t failed: removed the new files, nginx was not reloaded" >&2
    exit 1
  fi
  sudo systemctl reload nginx
fi

# --- the two ttyd services ---
run pkill -u "$USER" -x ttyd || true
run mkdir -p "$unitdir"
for a in "${apps[@]}"; do
  run install -m 644 "$here/web-ttyd-$a.service" "$unitdir/web-ttyd-$a.service"
done
run systemctl --user daemon-reload
for a in "${apps[@]}"; do run systemctl --user enable --now "web-ttyd-$a.service"; done
run sudo loginctl enable-linger "$USER"

say "Done.  https://192.168.10.1:8444/  (maze4/ and bidet/)  status: systemctl --user status 'web-ttyd-*'"
