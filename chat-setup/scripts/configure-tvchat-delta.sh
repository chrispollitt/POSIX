#!/usr/bin/env bash
#
# configure-tvchat-delta.sh
#
# The client half of mail-setup's configure-delta.sh: set tvchat up with a
# Delta Chat account on a mailbox you already have (made by that script, or
# any IMAP/SMTP mailbox that is yours alone - Delta Chat moves and may delete
# its mail, so never your everyday inbox).  Run it as yourself on the client
# machine - no root.  The script:
#
#   1. makes sure the official Delta Chat core, `deltachat-rpc-server`, is
#      there: on PATH, else `pip install --user deltachat-rpc-server`; if
#      that is not possible it says how to get the release binary instead;
#   2. writes [account:ACCOUNT] into ~/.config/tvchat/tvchat.conf (or
#      $TVCHAT_CONF), added or replaced - every other section and comment is
#      kept, the file is backed up first - with `rpc_server =` set to the
#      full path when the core is not on PATH.  With --autoconnect the
#      account joins [chat] autoconnect;
#   3. the mailbox password: looked up the way tvchat will (the installed
#      tvchat-backend's own lookup: $TVCHAT_PASS_<ACCOUNT>, ~/.mu-tickets,
#      ~/.netrc - each only for the login) and kept if found; else asked for
#      (or $CHAT_SETUP_PASS) and added to ~/.netrc, mode 600;
#   4. connects once for real (the installed tvchat-backend, with the account's
#      own data directory) and reports "connected", or why not.  The first
#      connect sets the mailbox up, which takes a minute.
#
# Re-runnable.  Passwords never go into tvchat.conf or onto a command line.
#
# Usage:
#   ./configure-tvchat-delta.sh --addr ADDRESS [options]
#
# Options:
#   --addr ADDRESS      the mailbox's address, e.g. delta@cpbee.cmnet (required)
#   --user LOGIN        the IMAP / SMTP login (default: the part before the @)
#   --host HOST         the mail server (default: the part after the @)
#   --account NAME      the section name, [account:NAME] (default: delta)
#   --display TEXT      shown in tvchat's titles (default: Delta Chat)
#   --name TEXT         your name as the people you write to see it
#   --smtp-port N       submission port (default: 587; the core would try 465
#                       first and wait out a timeout)
#   --self-signed       the server's certificate is self-signed (mail-setup's
#                       is): verify = false
#   --autoconnect       add the account to [chat] autoconnect
#   --no-install        do not try to install the core
#   --no-check          skip the real connect (offline)
#   -h | --help         show this header
#
set -euo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# the shared helpers (log/warn/die/readsecret/find_python/backup) are mail-setup's
. "$here/../../mail-setup/lib/common.sh"

ADDR=""
LOGIN=""
HOST=""
ACCOUNT=delta
DISPLAY_NAME="Delta Chat"
NAME=""
SMTP_PORT=587
SELF_SIGNED=0
AUTOCONNECT=0
INSTALL=1
CHECK=1

while [ $# -gt 0 ]; do
  case "$1" in
    --addr)        ADDR="${2:?}"; shift 2 ;;
    --user)        LOGIN="${2:?}"; shift 2 ;;
    --host)        HOST="${2:?}"; shift 2 ;;
    --account)     ACCOUNT="${2:?}"; shift 2 ;;
    --display)     DISPLAY_NAME="${2:?}"; shift 2 ;;
    --name)        NAME="${2:?}"; shift 2 ;;
    --smtp-port)   SMTP_PORT="${2:?}"; shift 2 ;;
    --self-signed) SELF_SIGNED=1; shift ;;
    --autoconnect) AUTOCONNECT=1; shift ;;
    --no-install)  INSTALL=0; shift ;;
    --no-check)    CHECK=0; shift ;;
    -h|--help)     usage "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$ADDR" ] || die "--addr is required (the mailbox's address)"
case "$ADDR" in *[!A-Za-z0-9._+@-]*|*@*@*|@*|*@) die "--addr: '$ADDR' is not an address" ;; esac
case "$ADDR" in *@*.*) : ;; *) die "--addr: '$ADDR' needs a domain with a dot (Delta Chat insists)" ;; esac
: "${LOGIN:=${ADDR%@*}}"
: "${HOST:=${ADDR#*@}}"
case "$LOGIN$HOST" in *[!A-Za-z0-9._+@-]*|'') die "--user and --host take plain names only" ;; esac
case "$SMTP_PORT" in ''|*[!0-9]*) die "--smtp-port must be a number" ;; esac
case "$ACCOUNT" in ''|*[/\\[:space:]]*|*]*) die "--account: no '/', '\\', ']' or whitespace" ;; esac
for v in "$DISPLAY_NAME" "$NAME"; do
  case "$v" in *$'\n'*|*' #'*|*' ;'*) die "'$v': no newlines, and no ' #' or ' ;' in a value" ;; esac
done

CONF="${TVCHAT_CONF:-$HOME/.config/tvchat/tvchat.conf}"
CONF_DIR=$(dirname -- "$CONF")
PASS_VAR="TVCHAT_PASS_$(printf '%s' "$ACCOUNT" | tr -c 'A-Za-z0-9' '_' | tr 'a-z' 'A-Z')"
NETRC="$HOME/.netrc"
PY=$(find_python) || die "python3 (3.6 or later) is needed"

step "tvchat -> $ADDR as [account:$ACCOUNT]"
mkdir -p "$CONF_DIR"
chmod 700 "$CONF_DIR" 2>/dev/null || true

# 1. the core ----------------------------------------------------------------
RPC=deltachat-rpc-server
rpc_path=$(command -v "$RPC" 2>/dev/null || true)
if [ -z "$rpc_path" ] && [ "$INSTALL" = 1 ] && [ "$IS_CYGWIN" = 0 ]; then
  log "core        : not found - pip install --user deltachat-rpc-server"
  if "$PY" -m pip install --user --quiet deltachat-rpc-server >/dev/null 2>&1; then
    for d in "$("$PY" -c 'import sysconfig; print(sysconfig.get_path("scripts", "posix_user"))' 2>/dev/null || true)" \
             "$HOME/.local/bin" "$HOME/Library/Python/"*/bin; do
      for n in "$RPC" "$RPC.exe"; do
        [ -x "$d/$n" ] && "$d/$n" --version >/dev/null 2>&1 && { rpc_path="$d/$n"; break 2; }
      done
    done
  fi
fi
if [ -z "$rpc_path" ] && [ "$INSTALL" = 1 ] && [ "$IS_CYGWIN" = 1 ]; then
  # Cygwin has no wheel of its own: take the Windows build out of the PyPI one
  # (it runs from Cygwin; tvchat-backend hands it a Windows path for its data)
  log "core        : Cygwin - fetching the Windows build"
  wd=$(mktemp -d)
  if "$PY" -m pip download --quiet --no-deps --only-binary=:all: --platform win_amd64         --python-version 3 --dest "$wd" deltachat-rpc-server >/dev/null 2>&1; then
    mkdir -p "$HOME/.local/bin"
    if "$PY" - "$wd" "$HOME/.local/bin/deltachat-rpc-server.exe" <<'PYEOF2'
import glob, shutil, sys, zipfile
whl = glob.glob(sys.argv[1] + "/deltachat_rpc_server-*.whl")[0]
with zipfile.ZipFile(whl) as z, open(sys.argv[2], "wb") as out:
    shutil.copyfileobj(z.open("deltachat_rpc_server/deltachat-rpc-server.exe"), out)
PYEOF2
    then
      chmod +x "$HOME/.local/bin/deltachat-rpc-server.exe"
      rpc_path="$HOME/.local/bin/deltachat-rpc-server.exe"
    fi
  fi
  rm -rf "$wd"
fi
if [ -z "$rpc_path" ]; then
  warn "no deltachat-rpc-server: install it (pip install deltachat-rpc-server, or a release"
  warn "binary from https://github.com/chatmail/core/releases onto PATH) and run this again"
  [ "$CHECK" = 0 ] || die "cannot check the account without the core (--no-check skips this)"
else
  log "core        : $rpc_path ($("$rpc_path" --version 2>/dev/null || echo '?'))"
fi
RPC_LINE=""
if [ -n "$rpc_path" ] && [ "$(command -v "$RPC" 2>/dev/null || true)" != "$rpc_path" ]; then
  RPC_LINE="rpc_server = $rpc_path"        # not on PATH: say where it is
fi

# 2. tvchat.conf -------------------------------------------------------------
section="[account:$ACCOUNT]
protocol    = deltachat
display     = $DISPLAY_NAME
addr        = $ADDR
# the mailbox login, and the mail server (autoconfiguration cannot guess a LAN one)
imap_user   = $LOGIN
imap_server = $HOST
smtp_user   = $LOGIN
smtp_server = $HOST
smtp_port   = $SMTP_PORT"
[ "$SELF_SIGNED" = 1 ] && section="$section
# the server's certificate is self-signed
verify      = false"
[ -n "$NAME" ] && section="$section
name        = $NAME"
[ -n "$RPC_LINE" ] && section="$section
$RPC_LINE"

result=$(SECTION="$section" "$PY" - "$CONF" "$ACCOUNT" "$AUTOCONNECT" <<'PYEOF'
# Text edit, not configparser.write(): that would drop every comment.
import configparser, os, re, shutil, sys, time
path, account, autoconnect = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
section = os.environ["SECTION"].rstrip("\n") + "\n"
try:
    with open(path, encoding="utf-8") as f:
        lines = f.read().splitlines(True)
    what = "added to"
except FileNotFoundError:
    lines = ["# tvchat configuration (read by tvchat-backend).\n",
             "# NO PASSWORDS HERE: ~/.netrc or $TVCHAT_PASS_<ACCOUNT>.\n", "\n"]
    what = "created"
if lines and not lines[-1].endswith("\n"):
    lines[-1] += "\n"
head = re.compile(r"\s*\[(.*)\]\s*$")

def span(name):
    """(first, end) lines of [name], end just past its last non-blank line"""
    start = None
    for i, l in enumerate(lines):
        m = head.match(l)
        if m and start is None and m.group(1).strip() == name:
            start = i
        elif m and start is not None:
            end = i
            break
    else:
        end = len(lines)
    if start is None:
        return None
    while end > start + 1 and (not lines[end - 1].strip() or lines[end - 1].lstrip().startswith(("#", ";"))):
        end -= 1
    return start, end

s = span("account:" + account)
if s:
    lines[s[0]:s[1]] = [section]
    what = "replaced in"
else:
    if lines and lines[-1].strip():
        lines.append("\n")
    lines.append(section)

if autoconnect:
    c = span("chat")
    if c is None:
        lines[0:0] = ["[chat]\n", "autoconnect = %s\n" % account, "\n"]
    else:
        for i in range(c[0] + 1, c[1]):
            m = re.match(r"(\s*autoconnect\s*[=:]\s*)(.*?)(\s*)$", lines[i])
            if m:
                names = [n.strip() for n in m.group(2).split(",") if n.strip()]
                if account not in names:
                    names.append(account)
                lines[i] = m.group(1) + ", ".join(names) + "\n"
                break
        else:
            lines.insert(c[0] + 1, "autoconnect = %s\n" % account)

text = "".join(lines)
if what != "created" and text == open(path, encoding="utf-8").read():
    print("unchanged in")
    sys.exit(0)
cp = configparser.ConfigParser(interpolation=None)
try:
    cp.read_string(text)
except configparser.Error as e:
    sys.exit("the edited file would not parse: %s" % str(e).splitlines()[0])
if what != "created":
    shutil.copy2(path, path + ".bak." + time.strftime("%Y%m%d-%H%M%S"))
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    f.write(text)
if os.path.exists(path):
    os.chmod(tmp, os.stat(path).st_mode & 0o777)
else:
    os.chmod(tmp, 0o600)
os.replace(tmp, path)
print(what)
PYEOF
) || die "could not update $CONF"
log "tvchat.conf : [account:$ACCOUNT] $result $CONF"
[ "$AUTOCONNECT" = 1 ] && log "autoconnect : $ACCOUNT"

# 3. the password ------------------------------------------------------------
# Found the way tvchat will find it: the installed tvchat-backend's own
# find_password_where() ($TVCHAT_BACKEND names another; empty: none, as in the
# tests).  Without a backend: $TVCHAT_PASS_<ACCOUNT>, then ~/.netrc for LOGIN.
BACKEND="${TVCHAT_BACKEND-$(command -v tvchat-backend 2>/dev/null || true)}"
if [ -z "${TVCHAT_BACKEND+set}" ] && [ -z "$BACKEND" ]; then
  # a bare ssh login has no /usr/local/bin on PATH: look where install.sh puts it
  for d in /usr/local/bin "$HOME/.local/bin" "$HOME/bin"; do
    [ -x "$d/tvchat-backend" ] && { BACKEND="$d/tvchat-backend"; break; }
  done
fi
find_where() {
  PASS_VAR="$PASS_VAR" "$PY" - "$ACCOUNT" "$HOST" "$LOGIN" "$BACKEND" "$NETRC" "$ADDR" <<'PYEOF'
import netrc, os, sys
account, host, login, backend, netrc_path, addr = sys.argv[1:7]
if backend and os.path.exists(backend):
    import importlib.machinery, importlib.util
    loader = importlib.machinery.SourceFileLoader("tvchat_backend", backend)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    if hasattr(mod, "find_delta_password"):
        pw, where = mod.find_delta_password(account, addr, host, login)
    else:
        pw, where = mod.find_password_where(account, host, login, "imap")
else:
    pw, where = None, None
    var = os.environ["PASS_VAR"]
    if os.environ.get(var):
        pw, where = os.environ[var], "$" + var
    else:
        try:
            a = netrc.netrc(netrc_path).authenticators(host)
        except (OSError, netrc.NetrcParseError):
            a = None
        if a and a[2] and a[0] == login:
            pw, where = a[2], "~/.netrc"
if pw:
    print(where)
sys.exit(0 if pw else 1)
PYEOF
}
if where=$(find_where); then
  log "password    : tvchat will use the one in $where"
else
  pw="${CHAT_SETUP_PASS:-}"
  if [ -z "$pw" ]; then
    pw=$(readsecret "password of $LOGIN on $HOST")
    [ "$pw" = "$(readsecret "again")" ] || die "the passwords differ"
  fi
  [ -n "$pw" ] || die "an empty password"
  case "$pw" in *[[:space:]]*|*'"'*) die "~/.netrc cannot hold a password with spaces or quotes - use \$$PASS_VAR" ;; esac
  [ -f "$NETRC" ] && backup "$NETRC"
  touch "$NETRC" && chmod 600 "$NETRC"
  [ -s "$NETRC" ] && [ -n "$(tail -c 1 "$NETRC")" ] && echo >> "$NETRC"
  printf 'machine %s login %s password %s\n' "$HOST" "$LOGIN" "$pw" >> "$NETRC"
  unset pw
  log "password    : added to ~/.netrc (machine $HOST, mode 600)"
  where=$(find_where) || die "tvchat's lookup does not find the password just added to ~/.netrc"
fi

# 4. a real connect ----------------------------------------------------------
if [ "$CHECK" = 1 ]; then
  [ -n "$BACKEND" ] || die "no tvchat-backend on PATH to connect with (install tvchat, or --no-check)"
  log "connect     : (the first time sets the mailbox up - up to a minute)"
  out=$(TVCHAT_CONF="$CONF" "$PY" - "$BACKEND" "$ACCOUNT" <<'PYEOF' 2>&1
import importlib.machinery, importlib.util, sys, time
loader = importlib.machinery.SourceFileLoader("tvchat_backend", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
cb = importlib.util.module_from_spec(spec)
loader.exec_module(cb)
chat = cb._chat()
acct = chat.account(sys.argv[2])
try:
    chat.connect(acct)
except cb.UserError as e:
    print(e)
    sys.exit(1)
end = time.time() + 180
chat.loop.running = True
while acct.state in ("disconnected", "connecting") and time.time() < end:
    chat.loop.run_once(0.1)
ok = acct.state == "connected"
print(acct.detail if acct.detail else acct.state)
chat.close()
sys.exit(0 if ok else 1)
PYEOF
  ) || die "could not connect $ADDR: $out (password from $where)"
  log "connect     : connected as $out"
fi

cat <<EOF

Done.  Start tvchat; Chat > $DISPLAY_NAME.  To talk to someone, one of you runs
Chat > Invite... and the other joins that link (Chat > Join...): the keys are
swapped once, then you can write.
EOF
