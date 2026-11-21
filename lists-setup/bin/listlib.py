"""listlib - what listserv (the command handler) and listctl (the list administrator's tool) share.

A list is an mlmmj list directory below SPOOL (default /var/spool/mlmmj), one directory per list:

    SPOOL/NAME/control/...        mlmmj's "tunables" (listaddress, owner, prefix, customheaders, closedlist, ...)
    SPOOL/NAME/subscribers.d/     the members, one file per first letter, one address per line
    SPOOL/NAME/digesters.d/       members who get the digest instead
    SPOOL/NAME/nomailsubs.d/      members who only post
    SPOOL/NAME/archive/ queue/ ...

mlmmj-make-ml is interactive, so create_list() makes the directories and files itself (the layout is documented in
mlmmj's README); members are changed with mlmmj's own mlmmj-sub / mlmmj-unsub, which do the locking.  Postfix reaches a
list through two tables kept in SPOOL, `virtual` and `transport` (regenerate_maps()), as mlmmj's README.postfix says.

Configuration is KEY=VALUE lines in /etc/lists-setup/lists.conf (or $LISTS_SETUP_CONF); every key can also be set in the
environment as LISTS_SETUP_KEY, which is what the tests do.
"""
import os
import re
import shutil
import subprocess
import sys
import time

CONF = "/etc/lists-setup/lists.conf"
DEFAULTS = {
    "SPOOL": "/var/spool/mlmmj",          # the mlmmj spool: one directory per list
    "DOMAIN": "",                         # list addresses are NAME@DOMAIN (required)
    "ADDRESS": "",                        # the list server's address (default listserv@DOMAIN)
    "SENDMAIL": "/usr/sbin/sendmail",     # how listserv sends its answers
    "MLMMJ_BIN": "/usr/bin",              # where mlmmj-sub, mlmmj-unsub, ... are
    "MLMMJ_USER": "mlmmj",                # who owns the lists (Postfix runs mlmmj and listserv as this user)
    "SKEL": "/usr/share/mlmmj/text.skel",  # mlmmj's default texts, copied into a new list (SKEL/en if there is one)
    "REMOVED": "/var/backups/lists-setup",  # a removed list is moved here
    "POSTMAP": "postmap",
    "POSTFIX": "postfix",                 # `postfix reload` after the tables changed; empty = do not reload
    "DIGEST_INTERVAL": "86400",           # seconds between digests of a new list (mlmmj's own default is a week)
}
RESERVED = {"listserv", "postmaster", "abuse", "root", "mailer-daemon", "owner", "nobody", "mlmmj"}
LIST_NAME = re.compile(r"^[a-z0-9](?:[a-z0-9_.]|-(?!-))*$")
MEMBER_DIRS = ("subscribers.d", "digesters.d", "nomailsubs.d")
LAYOUT = ("incoming", "queue", "queue/discarded", "archive", "text", "subconf", "unsubconf", "bounce", "control",
          "moderation", "subscribers.d", "digesters.d", "nomailsubs.d", "requeue")


class ListError(Exception):
    """Something to tell the person who asked (a reply line or a listctl message), not a crash."""


def load_config(path=None, env=None):
    env = os.environ if env is None else env
    cfg = dict(DEFAULTS)
    path = path or env.get("LISTS_SETUP_CONF") or CONF
    if os.path.exists(path):
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.split("#", 1)[0].strip()
                if "=" not in line:
                    continue
                k, v = line.split("=", 1)
                k = k.strip().upper()
                v = v.strip().strip("\"'")
                if k in cfg:
                    cfg[k] = v
    for k in cfg:
        if "LISTS_SETUP_" + k in env:
            cfg[k] = env["LISTS_SETUP_" + k]
    if not cfg["DOMAIN"]:
        raise ListError("DOMAIN is not set (%s)" % path)
    if not cfg["ADDRESS"]:
        cfg["ADDRESS"] = "listserv@" + cfg["DOMAIN"]
    return cfg


# ---------------------------------------------------------------------------------------------------- names ---
def valid_name(name):
    return bool(LIST_NAME.match(name or "")) and name not in RESERVED and len(name) <= 60


def check_name(name):
    name = (name or "").strip().lower()
    if not LIST_NAME.match(name):
        raise ListError("'%s' is not a list name (lowercase letters, digits, . _ and single -)" % name)
    if name in RESERVED:
        raise ListError("'%s' is reserved" % name)
    return name


def list_dir(cfg, name):
    return os.path.join(cfg["SPOOL"], name)


def list_names(cfg):
    try:
        entries = sorted(os.listdir(cfg["SPOOL"]))
    except OSError:
        return []
    return [n for n in entries if valid_name(n) and os.path.isdir(os.path.join(cfg["SPOOL"], n, "control"))]


def need_list(cfg, name):
    name = (name or "").strip().lower()
    if not valid_name(name) or name not in list_names(cfg):
        raise ListError("no such list: %s" % name)
    return name


# -------------------------------------------------------------------------------------------- control files ---
def _control(cfg, name, key):
    return os.path.join(list_dir(cfg, name), "control", key)


def has_control(cfg, name, key):
    return os.path.exists(_control(cfg, name, key))


def read_control(cfg, name, key, default=""):
    """The first line of a control file (mlmmj's "normal" file), or the default."""
    try:
        with open(_control(cfg, name, key), encoding="utf-8", errors="replace") as fh:
            return fh.readline().strip() or default
    except OSError:
        return default


def read_control_lines(cfg, name, key):
    try:
        with open(_control(cfg, name, key), encoding="utf-8", errors="replace") as fh:
            return [ln.strip() for ln in fh if ln.strip()]
    except OSError:
        return []


def write_control(cfg, name, key, value=None):
    """Write a control file: value None = a boolean (the file exists), a list = one per line, else one line."""
    p = _control(cfg, name, key)
    if value is None:
        text = ""
    elif isinstance(value, (list, tuple)):
        text = "".join(v + "\n" for v in value)
    else:
        text = value + "\n"
    with open(p, "w", encoding="utf-8") as fh:
        fh.write(text)
    _chown(cfg, p)


def remove_control(cfg, name, key):
    try:
        os.unlink(_control(cfg, name, key))
    except OSError:
        pass


def _chown(cfg, path):
    """Make a file ours-to-mlmmj when we are root (listctl runs as root, mlmmj and listserv as the mlmmj user)."""
    if os.geteuid() != 0:
        return
    try:
        import pwd
        pw = pwd.getpwnam(cfg["MLMMJ_USER"])
        os.chown(path, pw.pw_uid, pw.pw_gid)
    except (KeyError, ImportError, OSError):
        pass


def _chown_tree(cfg, top):
    _chown(cfg, top)
    for root, dirs, files in os.walk(top):
        for n in dirs + files:
            _chown(cfg, os.path.join(root, n))


# ------------------------------------------------------------------------------------------------- members ---
def members(cfg, name, kind="subscribers.d"):
    """Sorted addresses (lowercase) in subscribers.d / digesters.d / nomailsubs.d."""
    out = set()
    d = os.path.join(list_dir(cfg, name), kind)
    try:
        files = os.listdir(d)
    except OSError:
        return []
    for f in files:
        try:
            with open(os.path.join(d, f), encoding="utf-8", errors="replace") as fh:
                out.update(ln.strip().lower() for ln in fh if ln.strip())
        except OSError:
            pass
    return sorted(out)


def membership(cfg, name, addr):
    """'normal', 'digest', 'nomail' or None for an address."""
    addr = addr.lower()
    for kind, label in (("subscribers.d", "normal"), ("digesters.d", "digest"), ("nomailsubs.d", "nomail")):
        if addr in members(cfg, name, kind):
            return label
    return None


def _mlmmj(cfg, tool, *args):
    exe = os.path.join(cfg["MLMMJ_BIN"], tool)
    try:
        p = subprocess.run([exe] + list(args), capture_output=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise ListError("cannot run %s: %s" % (tool, e))
    if p.returncode != 0:
        msg = (p.stderr or p.stdout or b"").decode("utf-8", "replace").strip().splitlines()
        raise ListError("%s failed (%s)" % (tool, msg[-1] if msg else "exit %d" % p.returncode))


def subscribe(cfg, name, addr, mode="normal"):
    """Put addr on the list; mode normal / digest / nomail (moving it from the version it was on)."""
    args = ["-L", list_dir(cfg, name), "-a", addr, "-q", "-f"]
    if mode == "digest":
        args.append("-d")
    elif mode == "nomail":
        args.append("-n")
    _mlmmj(cfg, "mlmmj-sub", *args)


def unsubscribe(cfg, name, addr):
    _mlmmj(cfg, "mlmmj-unsub", "-L", list_dir(cfg, name), "-a", addr, "-q", "-s")


# --------------------------------------------------------------------------------------------------- lists ---
def describe(cfg, name):
    """A dict of what a list is: description, owners, flags and the member counts."""
    return {
        "name": name,
        "address": "%s@%s" % (name, cfg["DOMAIN"]),
        "description": read_control(cfg, name, "description"),
        "owners": read_control_lines(cfg, name, "owner"),
        "moderated": has_control(cfg, name, "moderated"),
        "moderators": read_control_lines(cfg, name, "moderators") if has_control(cfg, name, "moderated") else [],
        "closed_sub": has_control(cfg, name, "closedlistsub"),
        "approval": has_control(cfg, name, "submod"),
        "members_only_post": has_control(cfg, name, "subonlypost"),
        "digest_interval": read_control(cfg, name, "digestinterval", "604800"),
        "subscribers": len(members(cfg, name, "subscribers.d")),
        "digesters": len(members(cfg, name, "digesters.d")),
        "nomail": len(members(cfg, name, "nomailsubs.d")),
    }


def create_list(cfg, name, description="", owners=(), moderated=False, moderators=(), closed_sub=False,
                open_post=False, digest_interval=None):
    name = check_name(name)
    d = list_dir(cfg, name)
    if os.path.exists(d):
        raise ListError("the list %s exists already" % name)
    os.makedirs(cfg["SPOOL"], exist_ok=True)
    for sub in LAYOUT:
        os.makedirs(os.path.join(d, sub), exist_ok=True)
    skel = cfg["SKEL"]
    if os.path.isdir(os.path.join(skel, "en")):
        skel = os.path.join(skel, "en")
    if os.path.isdir(skel):
        for f in os.listdir(skel):
            src = os.path.join(skel, f)
            if os.path.isfile(src):
                shutil.copy2(src, os.path.join(d, "text", f))
    addr = "%s@%s" % (name, cfg["DOMAIN"])
    write_control(cfg, name, "listaddress", addr)
    write_control(cfg, name, "owner", list(owners) or ["postmaster@" + cfg["DOMAIN"]])
    if description:
        write_control(cfg, name, "description", " ".join(description.split()))
    write_control(cfg, name, "prefix", "[%s]" % name)
    # List-Id is what the server's one Sieve rule files list mail by (lists-setup configure-lists.sh)
    write_control(cfg, name, "customheaders", ["List-Id: <%s.%s>" % (name, cfg["DOMAIN"])])
    write_control(cfg, name, "tocc")                    # the list address need not be in To:/Cc: (Bcc posts work)
    write_control(cfg, name, "closedlist")              # members come and go through listserv@, not mlmmj's own mails
    if not open_post:
        write_control(cfg, name, "subonlypost")
    if closed_sub:
        write_control(cfg, name, "closedlistsub")
    if moderated:
        write_control(cfg, name, "moderated")
        write_control(cfg, name, "moderators", list(moderators) or list(owners) or ["postmaster@" + cfg["DOMAIN"]])
    write_control(cfg, name, "digestinterval", str(digest_interval or cfg["DIGEST_INTERVAL"]))
    write_control(cfg, name, "digestmaxmails", "50")
    _chown_tree(cfg, d)
    return name


def remove_list(cfg, name):
    """Move the list away (its members and archive are kept in REMOVED) and return where it went."""
    name = need_list(cfg, name)
    os.makedirs(cfg["REMOVED"], exist_ok=True)
    dest = os.path.join(cfg["REMOVED"], "%s-%s" % (name, time.strftime("%Y%m%d-%H%M%S")))
    shutil.move(list_dir(cfg, name), dest)
    return dest


# ------------------------------------------------------------------------------------------ postfix tables ---
def map_text(cfg):
    """(virtual, transport) tables of every list, in the shape mlmmj's README.postfix gives.  `listserv` is the
    command handler: its own transport (master.cf `listserv`), reached the same way."""
    dom = cfg["DOMAIN"]
    v = ["# lists-setup: generated by listctl (listctl sync); do not edit",
         "%-40s %s" % ("listserv@" + dom, "listserv@localhost.mlmmj")]
    t = ["# lists-setup: generated by listctl (listctl sync); do not edit",
         "%-40s %s" % ("listserv@localhost.mlmmj", "listserv:")]
    for n in list_names(cfg):
        v.append("%-40s %s" % ("%s@%s" % (n, dom), "%s--%s@localhost.mlmmj" % (dom, n)))
        t.append("%-40s %s" % ("%s--%s@localhost.mlmmj" % (dom, n), "mlmmj:%s" % n))
    return "\n".join(v) + "\n", "\n".join(t) + "\n"


def write_maps(cfg):
    """Write SPOOL/virtual and SPOOL/transport (atomically) and return their paths."""
    virtual, transport = map_text(cfg)
    paths = []
    for fname, text in (("virtual", virtual), ("transport", transport)):
        p = os.path.join(cfg["SPOOL"], fname)
        tmp = p + ".new"
        os.makedirs(cfg["SPOOL"], exist_ok=True)
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.replace(tmp, p)
        paths.append(p)
    return paths


def regenerate_maps(cfg, reload=True):
    """The tables, postmap'ed, and Postfix told to reload (cfg POSTFIX empty or reload False: not)."""
    paths = write_maps(cfg)
    for p in paths:
        try:
            r = subprocess.run([cfg["POSTMAP"], p], capture_output=True, timeout=60)
        except (OSError, subprocess.TimeoutExpired) as e:
            raise ListError("cannot run postmap: %s" % e)
        if r.returncode != 0:
            raise ListError("postmap %s failed: %s" % (p, (r.stderr or b"").decode("utf-8", "replace").strip()))
    if reload and cfg["POSTFIX"]:
        try:
            r = subprocess.run([cfg["POSTFIX"], "reload"], capture_output=True, timeout=60)
        except (OSError, subprocess.TimeoutExpired) as e:
            raise ListError("cannot run postfix reload: %s" % e)
        if r.returncode != 0:
            raise ListError("postfix reload failed: %s" % (r.stderr or b"").decode("utf-8", "replace").strip())
    return paths


def log(msg):
    """syslog (mail facility) where there is one; silent otherwise."""
    try:
        import syslog
        syslog.openlog("lists-setup", 0, syslog.LOG_MAIL)
        syslog.syslog(syslog.LOG_INFO, msg)
    except Exception:
        pass
