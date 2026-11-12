#!/bin/bash
# RUN ON: the laptop (Cygwin), in a terminal you can type in.  With no argument it only PLANS and checks; nothing on cpbee changes.
#           net-utils/cpbee-sudo-mfa-setup.sh               plan + checks
#           APPLY=1 net-utils/cpbee-sudo-mfa-setup.sh      steps 1-4: code check for sudo, then root ssh off
#           APPLY=1 KEEP_ROOT_SSH=1 ...                                            steps 1-3 only (leave root ssh as it is)
#           DISABLE_ROOT_SSH=1 .../cpbee-sudo-mfa-setup.sh                         step 4 alone (needs sudo MFA working already)
# WHY:    a stolen ssh key for chris@cpbee should not be enough to become root.  sudo then asks for a one-time code as well as
#         the password.  This is the cpbee counterpart of what the webhost does at login (~/.bashrc runs ssh_auth.py), but done
#         in PAM, because a ~/.bashrc check can be skipped by running /usr/bin/sudo, a non-interactive shell or another shell.
#         The laptop side is net-login in sudo mode (POSIX/net-utils: sudo-mfa): it answers the password from ~/.netrc and the
#         code from get_mfa_code.py.
# WHAT:   1. (cpbee, one ssh -t session, your sudo password once) installs libpam-google-authenticator; makes a random seed;
#            stores the seed in the vault (MASTER tier only, never the service tier: `auth totp cpbee chris` then needs the vault
#            unlocked, which is the point) and in /etc/google-authenticator/chris (root-owned, 0400: chris cannot read it)
#         2. backs up /etc/pam.d/sudo to /etc/pam.d/BAK/sudo.STAMP (keeps the 3 newest) and adds, after @include common-auth:
#              auth required pam_google_authenticator.so secret=/etc/google-authenticator/${USER} user=root   # allowlist secret
#            A root-owned background timer puts the backup back after 5 minutes UNLESS step 2 confirms, so a mistake cannot
#            lock you out of sudo for good.
#         3. from the laptop: runs  sudo-mfa cpbee  (password from ~/.netrc, code from the vault) to touch /run/sudo-mfa-confirmed
#            on cpbee.  If that works it prints CONFIRMED and the timer does nothing.
#         4. ONLY if step 3 said CONFIRMED (so you cannot lose both ways in): turns direct root login off: PermitRootLogin no in
#            /etc/ssh/sshd_config.d/20-no-root-login.conf, checked with sshd -t, ssh reloaded (running sessions stay), and then
#            checks that  ssh root@cpbee  is refused.  It runs through sudo-mfa, so it also proves sudo works.  Skip with
#            KEEP_ROOT_SSH=1; run it alone later with DISABLE_ROOT_SSH=1.
#            NOTE (found 2026-11-12): root@cpbee with this laptop's key WORKS today, i.e. root ssh is NOT disabled.  Until it
#            is, sudo MFA protects nothing against someone holding that key.  Nothing in TO_BE_RUN/POSIX/TUIs uses root ssh.
# NEEDS:  (it asks for these itself when missing)  1. the vault unlocked      2. a line in ~/.netrc:  machine cpbee login chris password <your cpbee
#         sudo password>   (the plan tells you if it is missing; `auth render netrc` writes the vault's logins there)
#         3. net-login and get_mfa_code.py next to this script (net-utils/; it uses those, not the ones on PATH)
# UNDO:   ssh -t cpbee 'sudo cp -p /etc/pam.d/BAK/sudo.STAMP /etc/pam.d/sudo'   (the STAMP is printed; needs a working code, or wait for
#         the timer; if sudo is broken and root ssh is still open: ssh root@cpbee 'cp -p /etc/pam.d/BAK/sudo.STAMP /etc/pam.d/sudo')
#         root ssh back on: ssh -t cpbee 'sudo rm /etc/ssh/sshd_config.d/20-no-root-login.conf && sudo systemctl reload ssh'
#         To drop MFA for good: undo the PAM line, then `auth remove 2fa@cpbee chris` and sudo rm -r /etc/google-authenticator.
# SAFE:   no secret is printed except where you are told so (the phone-app line, step 1, only if PHONE=1).  Idempotent: run it again.
set -u
HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
NL=$HERE/net-login
GET=$HERE/get_mfa_code.py
HOST=${HOST:-cpbee}
ME=${ME:-chris}
STAMP=$(date +%Y%m%d-%H%M%S)
die() { echo "FAILED: $*"; exit 1; }
say() { printf '%s\n' "$*"; }

[[ -f $NL && -f $GET ]] || die "net-login / get_mfa_code.py not found next to this script ($HERE)"
command -v expect >/dev/null || die "expect is not installed"

# ---- checks (always) ---------------------------------------------------------------------------------------------------
say "== checks"
vault=locked
if ssh -o BatchMode=yes -o ConnectTimeout=8 $HOST auth list >/dev/null 2>&1; then vault=unlocked; fi
say "   vault on $HOST: $vault   $([ $vault = locked ] && echo '(unlock it: ssh -t cpbee auth unlock)')"
if grep -qE "^[[:space:]]*machine[[:space:]]+$HOST([[:space:]]|\$)" ~/.netrc 2>/dev/null || grep -qE "machine[[:space:]]+$HOST[[:space:]]" ~/.netrc 2>/dev/null; then netrc=present; else netrc=MISSING; fi
say "   ~/.netrc entry for $HOST (sudo password): $netrc"
if ssh -o BatchMode=yes -o ConnectTimeout=8 root@$HOST true >/dev/null 2>&1; then rootssh=OPEN; else rootssh=closed; fi
say "   ssh root@$HOST with this laptop's key: $rootssh"
have_seed=no; MFA_NO_VAULT= timeout 30 python3 "$GET" $HOST $ME >/dev/null 2>&1 && have_seed=yes
say "   a code for $HOST/$ME is already available (seed in the vault): $have_seed"
pam_state=$(ssh -o BatchMode=yes -o ConnectTimeout=8 $HOST 'grep -c pam_google_authenticator /etc/pam.d/sudo; dpkg -s libpam-google-authenticator >/dev/null 2>&1 && echo pkg-installed || echo pkg-missing' 2>/dev/null | tr '\n' ' ')
say "   cpbee sudo PAM already has the check / package: ${pam_state:-unknown}"

say ""
say "== plan"
say "   1  cpbee: apt install libpam-google-authenticator; seed -> vault (master tier) + /etc/google-authenticator/$ME (root 0400)"
say "   2  cpbee: back up /etc/pam.d/sudo -> /etc/pam.d/BAK/sudo.$STAMP, add the pam_google_authenticator line after @include common-auth,"
say "      start a 5-minute auto-revert timer"
say "   3  laptop: sudo-mfa $HOST touch /run/sudo-mfa-confirmed  (password from ~/.netrc, code from the vault)  -> CONFIRMED cancels the timer"
say "   4  after CONFIRMED only: disable direct root login (PermitRootLogin no in a drop-in; sshd -t; reload; check ssh root@$HOST is refused).  KEEP_ROOT_SSH=1 skips it"
say "   phone app (optional, PHONE=1 with APPLY=1): prints an otpauth:// line to paste into an authenticator app as a second copy of the seed"

if [[ ${APPLY:-0} != 1 && ${DISABLE_ROOT_SSH:-0} != 1 ]]; then
  say ""; say "PLAN ONLY: nothing was changed.  To do steps 1-4:  APPLY=1 $0"
  exit 0
fi

# ---- ask for whatever is missing ----------------------------------------------------------------------------------------
[[ -t 0 && -t 1 ]] || die "run this in a terminal: it may ask you for the vault passphrase and the sudo password"

if [[ $vault != unlocked ]]; then
  say ""; say "The vault on $HOST is locked.  Unlocking it now: type the vault passphrase when asked."
  ssh -t $HOST auth unlock || die "could not unlock the vault"
  ssh -o BatchMode=yes -o ConnectTimeout=8 $HOST auth list >/dev/null 2>&1 || die "the vault is still locked"
  vault=unlocked
  MFA_NO_VAULT= timeout 30 python3 "$GET" $HOST $ME >/dev/null 2>&1 && have_seed=yes
fi

if [[ $netrc != present ]]; then
  say ""; say "~/.netrc has no entry for $HOST.  sudo-mfa needs your sudo password for $ME on $HOST to answer sudo's prompt."
  read -r -s -p "sudo password for $ME on $HOST (not shown): " pw; echo
  [[ -n $pw ]] || die "no password given"   # allowlist secret
  tmpnetrc=$(mktemp); chmod 600 "$tmpnetrc"; trap 'rm -f "$tmpnetrc"' EXIT
  printf 'machine %s login %s password "%s"\n' "$HOST" "$ME" "$(printf '%s' "$pw" | sed 's/[\\"]/\\&/g')" >"$tmpnetrc"   # allowlist secret
  if [[ ${pam_state%% *} == 0 ]]; then
    # sudo does not ask for a code yet, so this proves the password before anything on cpbee is changed   # allowlist secret
    say "checking the password with a harmless  sudo true  on $HOST ..."
    MFA_NETRC=$tmpnetrc MFA_QUIET=1 "$NL" sudo $HOST true </dev/null || die "that password did not work for sudo on $HOST (nothing was changed)"
    say "   password ok"
  fi
  read -r -p "Save it in ~/.netrc (mode 600) so sudo-mfa can use it from now on? [Y/n] " ans
  if [[ ${ans:-Y} =~ ^[Yy] ]]; then
    mkdir -p ~/BAK
    [[ -f ~/.netrc ]] && cp -p ~/.netrc ~/BAK/.netrc.$STAMP && ls -1t ~/BAK/.netrc.* 2>/dev/null | tail -n +4 | while read -r old; do rm -f -- "$old"; done
    [[ -s ~/.netrc && $(tail -c1 ~/.netrc | wc -l) -eq 0 ]] && echo >>~/.netrc
    cat "$tmpnetrc" >>~/.netrc; chmod 600 ~/.netrc
    say "   saved (backup of the old file: ~/BAK/.netrc.$STAMP)"
  else
    say "   not saved: used for this run only."
    export MFA_NETRC=$tmpnetrc
  fi
  unset pw
  netrc=present
fi

# ---- step 4 (a function: used alone and after step 3) -----------------------------------------------------------------
disable_root_ssh() {
  say ""; say "== step 4: direct root login off (through sudo with its code)"
  local remote4 w
  remote4='set -e; f=/etc/ssh/sshd_config.d/20-no-root-login.conf
echo "PermitRootLogin no" > /tmp/20-no-root.$$ ; install -m 644 -o root -g root /tmp/20-no-root.$$ $f ; rm -f /tmp/20-no-root.$$
if ! sshd -t; then rm -f $f; echo "sshd -t FAILED; removed $f"; exit 1; fi
systemctl reload ssh 2>/dev/null || systemctl reload sshd
echo "ssh reloaded"'
  # a code can be used once (DISALLOW_REUSE): let the 30 s period pass after step 3 so this sudo gets a fresh one
  w=$(( 30 - $(date +%s) % 30 + 1 )); say "   waiting ${w}s for a fresh code"; sleep $w
  MFA_QUIET=1 "$NL" sudo $HOST "sh -c $(printf '%q' "$remote4")" || die "could not change sshd (see above); nothing is broken: the old setting is still in force"
  if ssh -o BatchMode=yes -o ConnectTimeout=8 root@$HOST true >/dev/null 2>&1; then die "root ssh still WORKS (another sshd setting wins?); check: ssh $HOST 'sudo sshd -T | grep -i permitroot'"; fi
  say "DONE: ssh root@$HOST is now refused.  Your own login and sudo (with a code) are unchanged."
  say "      undo: ssh -t $HOST 'sudo rm /etc/ssh/sshd_config.d/20-no-root-login.conf && sudo systemctl reload ssh'  (sudo-mfa $HOST ... does it with the code)"
}

if [[ ${DISABLE_ROOT_SSH:-0} == 1 ]]; then
  [[ $have_seed == yes ]] || die "no code available for $HOST/$ME: do the sudo MFA steps first"
  disable_root_ssh
  exit 0
fi

# ---- steps 1-2 ---------------------------------------------------------------------------------------------------------
[[ $vault == unlocked ]] || die "unlock the vault first:  ssh -t cpbee auth unlock"
[[ $netrc == present ]] || die "add  machine $HOST login $ME password <sudo password>  to ~/.netrc first (chmod 600)"
remote=$(cat <<'REMOTE'
set -u
stamp=$1; me=$2; phone=$3
D=/etc/google-authenticator
P=/etc/pam.d/sudo
LINE='auth required pam_google_authenticator.so secret=/etc/google-authenticator/${USER} user=root'   # allowlist secret
sudo -v || { echo "FAILED: sudo"; exit 1; }
dpkg -s libpam-google-authenticator >/dev/null 2>&1 || sudo apt-get install -y libpam-google-authenticator >/dev/null || { echo "FAILED: apt install"; exit 1; }
echo "package: ok"
if sudo test -s $D/$me; then
  echo "seed file $D/$me exists; kept"
else
  # the vault makes and keeps the seed (auth seed): the user's LAN-wide one, or the one this host already had; this machine only
  # needs a copy in a root-only file for PAM
  seed=$(auth get 2fa lan "$me" 2>/dev/null || true)
  [ -n "$seed" ] || seed=$(auth get 2fa cpbee "$me" 2>/dev/null || true)
  url=""
  if [ -z "$seed" ]; then
    out=$(auth seed lan "$me" --note "one-time code seed for $me on the LAN (sudo on cpbee uses it too)") || { echo "FAILED: the vault did not make a seed"; exit 1; }
    seed=$(printf '%s\n' "$out" | sed -n 1p); url=$(printf '%s\n' "$out" | sed -n 2p)
  fi
  [ -n "$seed" ] || { echo "FAILED: no seed"; exit 1; }
  [ -n "$url" ] || url="otpauth://totp/cmnet:$me?secret=$seed&issuer=cmnet"
  sudo install -d -m 700 -o root -g root $D
  printf '%s\n" RATE_LIMIT 3 30\n" WINDOW_SIZE 3\n" DISALLOW_REUSE\n" TOTP_AUTH\n' "$seed" | sudo tee $D/$me >/dev/null
  sudo chown root:root $D/$me; sudo chmod 400 $D/$me
  echo "seed: made by the vault (master tier) and copied to $D/$me"
  [ "$phone" = 1 ] && echo "phone app:  $url"
  unset seed
fi
# the vault must give a code that matches what the file holds
v=$(auth totp cpbee "$me" 2>/dev/null | tail -1)
case $v in [0-9][0-9][0-9][0-9][0-9][0-9]) echo "vault gives a code: ok" ;; *) echo "FAILED: the vault gives no code for 2fa@cpbee $me"; exit 1 ;; esac
if grep -q pam_google_authenticator $P; then
  echo "$P already has the check; unchanged"; echo "STAMP=none"; exit 0
fi
sudo install -d -m 755 /etc/pam.d/BAK
sudo cp -p $P /etc/pam.d/BAK/sudo.$stamp || { echo "FAILED: backup"; exit 1; }
tmp=$(mktemp); awk -v l="$LINE" '{print} /^@include common-auth/ {print l}' $P > $tmp
grep -q pam_google_authenticator $tmp || { echo "FAILED: no @include common-auth line to add after"; rm -f $tmp; exit 1; }
# the auto-revert first, so the change is never live without it
sudo rm -f /run/sudo-mfa-confirmed
sudo setsid nohup sh -c "sleep 300; [ -e /run/sudo-mfa-confirmed ] || cp -p /etc/pam.d/BAK/sudo.$stamp /etc/pam.d/sudo" </dev/null >/dev/null 2>&1 &
sleep 1
sudo install -m 644 -o root -g root $tmp $P && rm -f $tmp
# keep the 3 newest backups
ls -1t /etc/pam.d/BAK/sudo.* 2>/dev/null | tail -n +4 | while read -r old; do sudo rm -f -- "$old"; done
echo "PAM: line added; auto-revert in 5 minutes unless confirmed"; echo "STAMP=$stamp"
REMOTE
)
printf '%s\n' "$remote" | bash -n || die "the remote script does not parse"
say ""; say "== steps 1-2 on $HOST (one sudo password prompt)"   # allowlist secret
printf '%s\n' "$remote" | ssh $HOST 'cat > ~/.sudo-mfa-setup.sh' || die "could not copy the remote script to $HOST"
# no pipe on this ssh: a pipe would hold back sudo's "[sudo] password" prompt (it has no newline) and look like a hang
ssh -t $HOST "bash ~/.sudo-mfa-setup.sh $STAMP $ME ${PHONE:-0}; rc=\$?; rm -f ~/.sudo-mfa-setup.sh; exit \$rc" \
  || die "step 1-2 failed (see above); nothing further was done"

# ---- step 3 ------------------------------------------------------------------------------------------------------------
say ""; say "== step 3: sudo with password + code, from the laptop"
if MFA_QUIET=0 "$NL" sudo $HOST touch /run/sudo-mfa-confirmed; then
  if ssh -o BatchMode=yes $HOST 'test -e /run/sudo-mfa-confirmed' ; then
    say "CONFIRMED: sudo on $HOST now needs password + code, and the laptop answers both.  The auto-revert timer will do nothing."
    if [[ ${KEEP_ROOT_SSH:-0} == 1 ]]; then
      say "KEEP_ROOT_SSH=1: direct root login left as it is (still OPEN).  Later: DISABLE_ROOT_SSH=1 $0"
    else
      disable_root_ssh
    fi
    say "All done.  Move this script to DONE/."
    exit 0
  fi
fi
say "NOT CONFIRMED.  The PAM change reverts itself within 5 minutes (backup /etc/pam.d/BAK/sudo.$STAMP)."
say "If you need sudo sooner and root ssh is still open:  ssh root@$HOST 'cp -p /etc/pam.d/BAK/sudo.$STAMP /etc/pam.d/sudo'"
exit 1
