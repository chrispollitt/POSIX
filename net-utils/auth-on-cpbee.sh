#!/bin/bash
# RUN ON: the laptop (it ssh's to cpbee).  Puts the auth-manager (phase 1) on cpbee:
#   1. installs `auth` and `identity` in /usr/local/bin (sudo, asked on cpbee)
#   2. lets gpg-agent keep the vault passphrase for 8 hours (max 24)
#   3. `auth init`: makes the key `auth-vault` and an empty vault (YOU choose the passphrase, at the prompt)
#   4. `auth init-service`: makes the passphrase-less key `auth-service` and an empty service tier (for jobs)
# Safe to run again: an existing vault is left alone.  Never contains a password.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
HOST=cpbee
echo "== copying auth and identity to $HOST"
scp "$HERE/auth" "$HERE/identity" "$HOST":/tmp/
echo "== installing, agent cache time, init (cpbee asks for the sudo password, then the new vault passphrase)"
ssh -t "$HOST" 'set -e
  sudo install -m 755 /tmp/auth /tmp/identity /usr/local/bin/ && rm -f /tmp/auth /tmp/identity
  command -v pinentry >/dev/null || { echo "no pinentry on cpbee: sudo apt install pinentry-curses"; exit 1; }
  mkdir -p -m 700 ~/.gnupg
  grep -q default-cache-ttl ~/.gnupg/gpg-agent.conf 2>/dev/null || printf "default-cache-ttl 28800\nmax-cache-ttl 86400\n" >> ~/.gnupg/gpg-agent.conf
  gpgconf --kill gpg-agent || true
  export GPG_TTY=$(tty)
  auth init
  auth unlock
  auth list
  auth init-service'
echo "== done: from this laptop try   ssh -t $HOST auth unlock   then   auth list"
