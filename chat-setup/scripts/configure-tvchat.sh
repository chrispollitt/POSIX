#!/usr/bin/env bash
#
# configure-tvchat.sh
#
# The client half of configure-ergo.sh: point tvmail's chat at an IRC server
# set up by it (or any IRC server whose CA you can fetch).  Run it as
# yourself on the client machine - no root.  The script:
#
#   1. fetches the server's CA (by default scp HOST:/opt/ergo/ca.pem, so ssh's
#      known_hosts vouches for it; --ca FILE uses a local copy instead) to
#      ~/.config/tvmail/ACCOUNT-ca.pem;
#   2. checks that a TLS connection to HOST:PORT verifies against it - the
#      way tvchat-backend will (Python's ssl, hostname checked);
#   3. writes [account:ACCOUNT] into ~/.config/tvmail/tvchat.conf (or
#      $TVCHAT_CONF): added, or replaced if it is there - every other section
#      and comment is kept, and the file is backed up first.  cafile gets the
#      full path (tvchat-backend does not expand ~).  With --autoconnect the
#      account joins [chat] autoconnect;
#   4. the SASL password: looked up the way tvmail will (the installed
#      tvchat-backend's own lookup: $TVCHAT_PASS_<ACCOUNT>, ~/.mu-tickets,
#      ~/.netrc - each only for NICK) and kept if found; else asked for (or
#      $CHAT_SETUP_PASS) and added to ~/.netrc, mode 600;
#   5. logs in with SASL PLAIN once with that password (a throwaway nick,
#      quits before registering) to show the account and password work.
#
# Re-runnable.  Passwords never go into tvchat.conf or onto a command line.
#
# Usage:
#   ./configure-tvchat.sh --nick NICK [options]
#
# Options:
#   --nick NICK         your nick, and the SASL account (required)
#   --host HOST         the server, as its certificate names it (default: cpbee)
#   --port N            TLS port (default: 6697)
#   --account NAME      the section name, [account:NAME] (default: HOST's
#                       first label)
#   --display TEXT      shown in tvmail's titles (default: NAME, or
#                       NAME (HOST) when they differ)
#   --channels LIST     joined on connect, comma-separated (default: #test)
#   --realname TEXT     (default: the one tvchat.conf already uses, else
#                       your name from getent, else NICK)
#   --remote-ca PATH    where the CA is on HOST (default: /opt/ergo/ca.pem)
#   --ca FILE           use this local CA file instead of fetching one
#   --no-sasl           connect unauthenticated: no sasl =, no password
#   --autoconnect       add the account to [chat] autoconnect
#   --no-check          skip the TLS and SASL checks (offline)
#   -h | --help         show this header
#
set -euo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# the shared helpers (log/warn/die/readsecret/find_python) are mail-setup's
. "$here/../../mail-setup/lib/common.sh"

NICK=""
HOST=cpbee
PORT=6697
ACCOUNT=""
DISPLAY_NAME=""
CHANNELS="#test"
REALNAME=""
REMOTE_CA=/opt/ergo/ca.pem
LOCAL_CA=""
SASL=1
AUTOCONNECT=0
CHECK=1

while [ $# -gt 0 ]; do
  case "$1" in
    --nick)        NICK="${2:?}"; shift 2 ;;
    --host)        HOST="${2:?}"; shift 2 ;;
    --port)        PORT="${2:?}"; shift 2 ;;
    --account)     ACCOUNT="${2:?}"; shift 2 ;;
    --display)     DISPLAY_NAME="${2:?}"; shift 2 ;;
    --channels)    CHANNELS="${2:?}"; shift 2 ;;
    --realname)    REALNAME="${2:?}"; shift 2 ;;
    --remote-ca)   REMOTE_CA="${2:?}"; shift 2 ;;
    --ca)          LOCAL_CA="${2:?}"; shift 2 ;;
    --no-sasl)     SASL=0; shift ;;
    --autoconnect) AUTOCONNECT=1; shift ;;
    --no-check)    CHECK=0; shift ;;
    -h|--help)     usage "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$NICK" ] || die "--nick is required (your nick, and the SASL account)"
case "$NICK" in -*|*[!A-Za-z0-9_\`^{}\|\[\]\\-]*) die "--nick: '$NICK' is not a valid nickname" ;; esac
case "$PORT" in ''|*[!0-9]*) die "--port must be a number" ;; esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "--port must be 1-65535"
case "$HOST" in ''|-*|*[!A-Za-z0-9.:-]*) die "--host: '$HOST' is not a host name or address" ;; esac
: "${ACCOUNT:=${HOST%%.*}}"
case "$ACCOUNT" in ''|*[/\\[:space:]]*|*]*) die "--account: no '/', '\\', ']' or whitespace" ;; esac
if [ -z "$DISPLAY_NAME" ]; then
  if [ "$ACCOUNT" = "$HOST" ]; then DISPLAY_NAME=$ACCOUNT; else DISPLAY_NAME="$ACCOUNT ($HOST)"; fi
fi
CONF="${TVCHAT_CONF:-$HOME/.config/tvmail/tvchat.conf}"
if [ -z "$REALNAME" ] && [ -f "$CONF" ]; then   # the one another account already uses
  REALNAME=$(sed -n 's/^[[:space:]]*realname[[:space:]]*[=:][[:space:]]*//p' "$CONF" | head -1)
fi
if [ -z "$REALNAME" ]; then   # not Cygwin's "U-HOST\user,S-1-5-..."
  REALNAME=$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f5 | cut -d, -f1 || true)
  case "$REALNAME" in *\\*) REALNAME="" ;; esac
fi
: "${REALNAME:=$NICK}"
# values go into an INI file: one line each, and no inline comment to misread
for v in "$DISPLAY_NAME" "$CHANNELS" "$REALNAME"; do
  case "$v" in *$'\n'*|*' #'*|*' ;'*) die "'$v': no newlines, and no ' #' or ' ;' in a value" ;; esac
done

PY=$(find_python) || die "python3 (3.6 or later, with ssl) is needed"
CONF_DIR=$(dirname -- "$CONF")
CAFILE="$CONF_DIR/$ACCOUNT-ca.pem"
PASS_VAR="TVCHAT_PASS_$(printf '%s' "$ACCOUNT" | tr -c 'A-Za-z0-9' '_' | tr 'a-z' 'A-Z')"
NETRC="$HOME/.netrc"

step "tvmail chat -> $NICK@$HOST:$PORT as [account:$ACCOUNT]"
mkdir -p "$CONF_DIR"
chmod 700 "$CONF_DIR" 2>/dev/null || true

# a ~/.netrc that cannot take the password stops us before anything changes:
# 0 = has machine HOST for NICK, 1 = has not, 2 = for another login / unreadable
netrc_has=1
if [ "$SASL" = 1 ] && [ -z "${!PASS_VAR:-}" ] && [ -f "$NETRC" ]; then
  netrc_has=0
  err=$("$PY" - "$NETRC" "$HOST" "$NICK" <<'PYEOF' 2>&1
import netrc, sys
try:
    a = netrc.netrc(sys.argv[1]).authenticators(sys.argv[2])
except (OSError, netrc.NetrcParseError) as e:
    print(e)
    sys.exit(2)
if a and a[0] != sys.argv[3]:
    print("it has machine %s for login %s, not %s" % (sys.argv[2], a[0], sys.argv[3]))
    sys.exit(2)
sys.exit(0 if a and a[2] else 1)
PYEOF
  ) || netrc_has=$?
  [ "$netrc_has" != 2 ] || die "~/.netrc: $err - fix it by hand (one machine $HOST line), or set \$$PASS_VAR"
fi

# 1. the CA ------------------------------------------------------------------
t=$(mktemp)
trap 'rm -f "$t"' EXIT
if [ -n "$LOCAL_CA" ]; then
  cp -- "$LOCAL_CA" "$t" || die "cannot read $LOCAL_CA"
  src="$LOCAL_CA"
else
  scp -q "$HOST:$REMOTE_CA" "$t" \
    || die "could not fetch $HOST:$REMOTE_CA (re-run configure-ergo.sh on $HOST, or give --ca FILE)"
  src="$HOST:$REMOTE_CA"
fi
grep -q -- '-----BEGIN CERTIFICATE-----' "$t" || die "$src holds no PEM certificate"
if cmp -s "$t" "$CAFILE" 2>/dev/null; then
  log "ca          : $CAFILE (unchanged)"
else
  backup "$CAFILE"
  cp -- "$t" "$CAFILE" && chmod 644 "$CAFILE"
  log "ca          : $src -> $CAFILE"
fi

# 2. TLS ---------------------------------------------------------------------
if [ "$CHECK" = 1 ]; then
  out=$("$PY" - "$HOST" "$PORT" "$CAFILE" <<'PYEOF' 2>&1
import socket, ssl, sys
host, port, cafile = sys.argv[1], int(sys.argv[2]), sys.argv[3]
ctx = ssl.create_default_context(cafile=cafile)
try:
    s = ctx.wrap_socket(socket.create_connection((host, port), 10), server_hostname=host)
except (OSError, ssl.SSLError) as e:
    print(e)
    sys.exit(1)
print("%s, %s" % (s.version(), s.cipher()[0]))
s.close()
PYEOF
  ) || die "TLS to $HOST:$PORT does not verify against $CAFILE: $out"
  log "tls         : $HOST:$PORT verifies ($out)"
fi

# 3. tvchat.conf -------------------------------------------------------------
section="[account:$ACCOUNT]
protocol = irc
display  = $DISPLAY_NAME
# must match the server's certificate
host     = $HOST
port     = $PORT
tls      = true
verify   = true
cafile   = $CAFILE
nick     = $NICK
realname = $REALNAME"
if [ "$SASL" = 1 ]; then
  section="$section
# SASL account; the password is in ~/.netrc (machine $HOST) or \$$PASS_VAR
sasl     = $NICK"
fi
section="$section
channels = $CHANNELS"

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
    lines = ["# tvchat-backend configuration - the chat side of tvmail.\n",
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
    # a comment block just above the next header belongs to that header
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
if what != "created" and text == "".join(open(path, encoding="utf-8").read()):
    print("unchanged in")
    sys.exit(0)
cp = configparser.ConfigParser(interpolation=None)
try:
    cp.read_string(text)
except configparser.Error as e:
    sys.exit("the edited file would not parse: %s" % str(e).splitlines()[0])
if what != "created":   # as common.sh's backup()
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

# 4. the password ------------------------------------------------------------
# Found the way tvmail will find it: the installed tvchat-backend's own
# find_password_where() ($TVCHAT_BACKEND names another), so the check in 5.
# sends what tvmail will send.  An older backend without it (before bug #46:
# ~/.mu-tickets could hand over another user's password) gets a warning and
# the same order done here: $TVCHAT_PASS_<ACCOUNT>, then ~/.netrc for NICK.
# ($TVCHAT_BACKEND= empty: none, as in the tests)
BACKEND="${TVCHAT_BACKEND-$(command -v tvchat-backend 2>/dev/null || true)}"
export LOOKUP_PY='
def lookup(account, host, nick, backend, pass_var, netrc_path):
    """(password, where) or (None, None); "(old)" after where = the backend
    has no find_password_where()"""
    import netrc, os
    old = ""
    if backend and os.path.exists(backend):
        import importlib.machinery, importlib.util
        loader = importlib.machinery.SourceFileLoader("tvchat_backend", backend)
        spec = importlib.util.spec_from_loader(loader.name, loader)
        mod = importlib.util.module_from_spec(spec)
        loader.exec_module(mod)
        if hasattr(mod, "find_password_where"):
            return mod.find_password_where(account, host, nick, "irc")
        old = " (old)"
    if os.environ.get(pass_var):
        return os.environ[pass_var], "$" + pass_var + old
    try:
        a = netrc.netrc(netrc_path).authenticators(host)
    except (OSError, netrc.NetrcParseError):
        a = None
    if a and a[2] and a[0] == nick:
        return a[2], "~/.netrc" + old
    return None, None
'
find_where() {   # -> where tvmail's lookup finds the password; 1 if nowhere
  PASS_VAR="$PASS_VAR" "$PY" - "$ACCOUNT" "$HOST" "$NICK" "$BACKEND" "$NETRC" <<'PYEOF'
import os, sys
exec(os.environ["LOOKUP_PY"])
pw, where = lookup(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], os.environ["PASS_VAR"], sys.argv[5])
if pw:
    print(where)
sys.exit(0 if pw else 1)
PYEOF
}
have_pass=""; where=""
if [ "$SASL" = 1 ]; then
  [ -n "$BACKEND" ] || warn "no tvchat-backend on PATH: looking in \$$PASS_VAR and ~/.netrc only"
  if where=$(find_where); then
    case "$where" in *"(old)") warn "the installed tvchat-backend predates bug #46's fix: tvmail may send another password (from ~/.mu-tickets) - update it" ;; esac
    log "password    : tvmail will use the one in ${where%% (*}"
    where=${where%% (*}; have_pass=1
  else
    pw="${CHAT_SETUP_PASS:-}"
    if [ -z "$pw" ]; then
      pw=$(readsecret "NickServ password for $NICK on $HOST")
      [ "$pw" = "$(readsecret "again")" ] || die "the passwords differ"
    fi
    [ -n "$pw" ] || die "an empty password"
    case "$pw" in *[[:space:]]*|*'"'*) die "~/.netrc cannot hold a password with spaces or quotes - use \$$PASS_VAR" ;; esac
    [ -f "$NETRC" ] && backup "$NETRC"
    touch "$NETRC" && chmod 600 "$NETRC"
    [ -s "$NETRC" ] && [ -n "$(tail -c 1 "$NETRC")" ] && echo >> "$NETRC"
    printf 'machine %s login %s password %s\n' "$HOST" "$NICK" "$pw" >> "$NETRC"
    unset pw
    log "password    : added to ~/.netrc (machine $HOST, mode 600)"
    where=$(find_where) || die "tvmail's lookup does not find the password just added to ~/.netrc"
    where=${where%% (*}; have_pass=1
  fi
fi

# 5. a SASL login ------------------------------------------------------------
if [ "$CHECK" = 1 ] && [ -n "$have_pass" ]; then
  out=$(PASS_VAR="$PASS_VAR" "$PY" - "$HOST" "$PORT" "$CAFILE" "$NICK" "$NETRC" "$ACCOUNT" "$BACKEND" <<'PYEOF' 2>&1
import base64, os, random, socket, ssl, sys
host, port, cafile, nick, netrc_path = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
exec(os.environ["LOOKUP_PY"])
pw = lookup(sys.argv[6], host, nick, sys.argv[7], os.environ["PASS_VAR"], netrc_path)[0]
ctx = ssl.create_default_context(cafile=cafile)
s = ctx.wrap_socket(socket.create_connection((host, port), 10), server_hostname=host)
s.settimeout(15)
send = lambda line: s.sendall((line + "\r\n").encode("utf-8"))
send("CAP LS 302")
send("NICK tvchk%04d" % random.randrange(10000))
send("USER tvchk 0 * :configure-tvchat.sh check")
buf, verdict, caps = b"", None, []
while verdict is None:
    data = s.recv(4096)
    if not data:
        verdict = (1, "the server hung up")
        break
    buf += data
    while b"\r\n" in buf:
        raw, buf = buf.split(b"\r\n", 1)
        words = raw.decode("utf-8", "replace").split(" ")
        if words[0].startswith("@"):
            words = words[1:]
        if words[0].startswith(":"):
            words = words[1:]
        cmd = words[0].upper() if words else ""
        if cmd == "PING":
            send("PONG " + " ".join(words[1:]))
        elif cmd == "CAP" and len(words) > 3 and words[2] == "LS":
            # CAP * LS * :a b   (more to come)   /   CAP * LS :c d=e   (the last)
            more = words[3] == "*"
            caps += [c.split("=")[0] for c in " ".join(words[4 if more else 3:]).lstrip(":").split()]
            if more:
                continue
            if "sasl" not in caps:
                verdict = (1, "the server offers no SASL")
            else:
                send("CAP REQ :sasl")
        elif cmd == "CAP" and len(words) > 2 and words[2] == "ACK":
            send("AUTHENTICATE PLAIN")
        elif cmd == "AUTHENTICATE" and words[1:2] == ["+"]:
            send("AUTHENTICATE " + base64.b64encode(
                ("%s\0%s\0%s" % (nick, nick, pw)).encode("utf-8")).decode("ascii"))
        elif cmd == "903":
            verdict = (0, "logged in as %s" % nick)
        elif cmd in ("902", "904", "905", "906", "908"):
            verdict = (1, " ".join(words[2:]).lstrip(":") or cmd)
        elif cmd == "ERROR":
            verdict = (1, " ".join(words[1:]).lstrip(":"))
        if verdict:
            break
try:
    send("QUIT :check done")
except OSError:
    pass
s.close()
print(verdict[1])
sys.exit(verdict[0])
PYEOF
  ) || die "SASL login as $NICK failed: $out (password from $where)"
  log "sasl        : $out"
fi

cat <<EOF

Done.  Start tvmail (tvmail --debug writes debug.chat.log beside debug.log);
Chat > Connect... > $DISPLAY_NAME, then Alt-C for its conversations.
EOF
