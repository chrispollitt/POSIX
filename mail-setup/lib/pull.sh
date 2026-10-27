# shellcheck shell=bash
# lib/pull.sh - pieces shared by the two pullers (configure-mail-pull.sh for
# pop-pull, configure-getmail.sh for getmail).  Source after lib/common.sh.
#
# Both install  $BIN/mail-pull , a two-line wrapper that runs whichever puller
# was configured LAST.  Callers (a timer, cron, tvmail's F3) run mail-pull and
# never need to know which one it is.  Exit status follows pop-pull's:
# 0 = got mail, 1 = nothing new, 2+ = error (getmail only ever gives 0 or error).

# write_mail_pull BIN BODY -> $BIN/mail-pull whose body is BODY (sh)
write_mail_pull() {
  _wp="$1/mail-pull"
  {
    echo '#!/bin/sh'
    echo "# mail-pull - fetch remote mail with the puller mail-setup configured last."
    echo "# Written $(date) by $(basename "$0"); re-run the other"
    echo "# configure-*.sh to switch.  Args: -v verbose, -n dry run (pop-pull only)."
    printf '%s\n' "$2"
  } > "$_wp"
  chmod 755 "$_wp"
  log "wrote $_wp"
}

CRON_TAG="# mail-setup: mail-pull"

# install_pull_cron MINUTES BIN -> a crontab line running $BIN/mail-pull
install_pull_cron() {
  _min="$1"; _bin="$2"
  if ! command -v crontab >/dev/null 2>&1; then
    warn "no systemd and no crontab - install cron, or run 'mail-pull' by hand"
    return 1
  fi
  if [ "$_min" -ge 60 ]; then _when="0 * * * *"; warn "cron: $_min min rounded to hourly"
  else _when="*/$_min * * * *"; fi
  { crontab -l 2>/dev/null | grep -vF "$CRON_TAG" || true
    echo "$_when $_bin/mail-pull >/dev/null 2>&1   $CRON_TAG"; } | crontab -
  log "crontab: mail-pull every $_min min  (crontab -l to see it)"
  pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1 || pgrep -f cygrunsrv.*cron >/dev/null 2>&1 \
    || warn "cron doesn't seem to be running - start it (e.g. sudo service cron start)"
}

remove_pull_cron() {
  command -v crontab >/dev/null 2>&1 || return 0
  crontab -l 2>/dev/null | grep -qF "$CRON_TAG" || return 0
  { crontab -l 2>/dev/null | grep -vF "$CRON_TAG" || true; } | crontab -
  log "removed the mail-pull crontab line (the systemd timer replaces it)"
}

# install_pull_timer MINUTES BIN -> systemd --user timer running $BIN/mail-pull,
# or a crontab line where there's no systemd (WSL, Cygwin, containers).
# MAIL_SETUP_NO_SYSTEMD=1 forces cron (tests).
install_pull_timer() {
  _min="$1"; _bin="$2"
  [ "$_min" != 0 ] && [ "$_min" -gt 0 ] 2>/dev/null || return 0
  if [ -n "${MAIL_SETUP_NO_SYSTEMD:-}" ] \
     || ! { command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; }; then
    install_pull_cron "$_min" "$_bin"
    return
  fi
  remove_pull_cron
  ud="$HOME/.config/systemd/user"; install -d -m 0700 "$ud"
  # units from before mail-setup was split out of tvmail
  if [ -e "$ud/tvmail-pull.timer" ]; then
    systemctl --user disable --now tvmail-pull.timer 2>/dev/null || true
    rm -f "$ud/tvmail-pull.timer" "$ud/tvmail-pull.service"
    log "removed the old tvmail-pull.timer (replaced by mail-pull.timer)"
  fi
  cat > "$ud/mail-pull.service" <<EOF
[Unit]
Description=mail-setup: fetch remote mail (mail-pull)
[Service]
Type=oneshot
ExecStart=$_bin/mail-pull
# exit 1 = "no new mail", not a failure
SuccessExitStatus=1
EOF
  cat > "$ud/mail-pull.timer" <<EOF
[Unit]
Description=mail-setup: pull mail every ${_min} min
[Timer]
OnBootSec=2min
OnUnitActiveSec=${_min}min
Persistent=true
[Install]
WantedBy=timers.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now mail-pull.timer
  log "systemd --user timer: mail-pull.timer (every ${_min} min)"
  log "  status:  systemctl --user list-timers mail-pull.timer"
  # a --user timer only runs while you're logged in, unless you linger
  if loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q '=yes'; then
    :
  elif loginctl enable-linger "$USER" 2>/dev/null; then
    log "  enabled lingering, so it runs while you're logged out too"
  else
    warn "run 'sudo loginctl enable-linger $USER' so it keeps pulling while you're logged out"
  fi
}

# find_mda -> $MAIL_SETUP_MDA, else the first executable sendmail-compatible
# MDA, or empty
find_mda() {
  for m in "${MAIL_SETUP_MDA:-}" /usr/sbin/sendmail /usr/lib/sendmail "$(command -v sendmail 2>/dev/null)"; do
    [ -n "$m" ] && [ -x "$m" ] && { echo "$m"; return 0; }
  done
  return 1
}

# relay_field FILE LABEL -> value of "LABEL: value" in a cPanel relay-info file
relay_field() {
  sed -n "s/^$2:[[:space:]]*//p" "$1" 2>/dev/null | head -1 | tr -d ' \r'
}
