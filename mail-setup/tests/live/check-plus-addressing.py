#!/usr/bin/env python3
"""check-plus-addressing.py - does YOUR mail host support plus-addresses?

NOT part of run-tests.sh: this one talks to the real servers.  Run it once
before turning on --plus-users / --plus-base, to settle what the mail-setup
scripts can't know about your ISP / web host (e.g. cPanel Exim + Dovecot):

  1. does the smarthost accept the envelope sender  cwp+chris@u-l.ca  when you
     log in as cwp@u-l.ca?                              (outbound per-user senders)
  2. where does mail to  cwp+chris@u-l.ca  land?  Two kinds of host exist:
       - it goes into the cwp@u-l.ca INBOX (header names the tag: pop-pull or
         getmail can route it by header), or
       - it goes into an IMAP FOLDER named after the tag (cPanel/Dovecot: the
         folder is INBOX.chris, auto-created).  POP3 can't see that at all;
         only getmail --imap can fetch it.                       (inbound)

It sends one probe message FROM cwp+TAG@domain TO cwp+TAG@domain through the
smarthost (SMTP submission, STARTTLS, AUTH), then polls the mailbox over IMAPS
(the INBOX and any folder named TAG) and POP3S (the inbox) for it, says where
it landed, which of Delivered-To / X-Original-To / To / Cc carried the tagged
address, prints a recommendation (getmail --imap, with the folder prefix it
found, vs pop-pull) and deletes the probe again (--keep to leave it).  If the
probe's delivery created the tag folder, that is deleted too.

    check-plus-addressing.py --relay-file smtp-relay.txt [--tag chris]

The password is read from Postfix's sasl_passwd (--pwfile), like pop-pull.
Exit status: 0 = sender accepted and the probe arrived somewhere routable,
1 = a check failed, 2 = couldn't run.
"""
import argparse, email, email.parser, email.utils, imaplib, os, re, smtplib, socket, ssl, sys, time, uuid, poplib

HEADERS = ("Delivered-To", "X-Original-To", "To", "Cc")
LIST_RE = re.compile(r'^\((?P<flags>[^)]*)\)\s+(?P<delim>"[^"]*"|NIL)\s+(?P<name>.+)$')


def die(msg, code=2):
    print("check-plus-addressing: " + msg, file=sys.stderr)
    sys.exit(code)


def relay_field(path, label):
    try:
        with open(path) as f:
            for ln in f:
                m = re.match(r"^%s:\s*(.*?)\s*$" % re.escape(label), ln.rstrip("\r\n"))
                if m:
                    return m.group(1).replace(" ", "")
    except OSError as e:
        die("cannot read %s: %s" % (path, e))
    return ""


def smtp_port(explicit, relay_value):
    """--smtp-port, else the relay file's "SMTP Port", else 465 (SMTPS): many
    networks and hosts block 25/587 (cp1/u-l.ca: only 26 and 465 answer)."""
    if explicit:
        return explicit
    digits = re.sub(r"\D", "", relay_value or "")
    return int(digits) if digits and int(digits) > 0 else 465


def password(pwfile, login):
    try:
        with open(pwfile) as f:
            for ln in f:
                fields = ln.strip().split(None, 1)
                if len(fields) == 2 and not ln.lstrip().startswith("#"):
                    user, sep, pw = fields[1].partition(":")
                    if sep and user == login:
                        return pw
    except OSError as e:
        die("cannot read %s: %s" % (pwfile, e))
    die("no password for %s in %s" % (login, pwfile))


def send_probe(a, login, pw, addr, token):
    """-> (ok, detail).  Sender and recipient are both ADDR."""
    msg = ("From: %s\r\nTo: %s\r\nSubject: plus-addressing probe %s\r\n"
           "Date: %s\r\nMessage-ID: <%s@plus-probe.invalid>\r\n\r\n"
           "mail-setup check-plus-addressing.py probe %s\r\n"
           % (addr, addr, token, email.utils.formatdate(localtime=True), token, token))
    try:
        if a.smtp_port == 465 and not a.no_tls:        # SMTPS: TLS from the first byte
            s = smtplib.SMTP_SSL(a.smtp_host, a.smtp_port, timeout=45,
                                 context=ssl.create_default_context())
        else:
            s = smtplib.SMTP(a.smtp_host, a.smtp_port, timeout=45)
        try:
            if not a.no_tls and a.smtp_port != 465:    # STARTTLS (587, 26, ...)
                s.starttls(context=ssl.create_default_context())
            if not a.no_auth:
                s.login(login, pw)
            refused = s.sendmail(addr, [addr], msg.encode())
        finally:
            try:
                s.quit()
            except Exception:
                pass
    except smtplib.SMTPSenderRefused as e:
        return False, "smarthost refused the sender %s: %s %s" % (addr, e.smtp_code, e.smtp_error.decode(errors="replace"))
    except smtplib.SMTPRecipientsRefused as e:
        return False, "smarthost refused the recipient %s: %s" % (addr, e.recipients)
    except (smtplib.SMTPException, OSError) as e:
        hint = ""
        if isinstance(e, (socket.timeout, TimeoutError, ConnectionRefusedError)):
            hint = (" - could not even connect to %s:%d; many networks block 25/587, "
                    "try --smtp-port 465 (SMTPS) or the host's alternate port" % (a.smtp_host, a.smtp_port))
        return False, "SMTP error: %s%s" % (e, hint)
    return (not refused), ("recipient refused: %s" % refused if refused else "accepted %s as sender and recipient" % addr)


# ---------------------------------------------------------------------------
# IMAP
# ---------------------------------------------------------------------------
def imap_open(a, login, pw):
    try:
        if a.no_tls:
            M = imaplib.IMAP4(a.imap_host, a.imap_port)
        else:
            M = imaplib.IMAP4_SSL(a.imap_host, a.imap_port, ssl_context=ssl.create_default_context())
        M.login(login, pw)
        return M
    except (imaplib.IMAP4.error, OSError) as e:
        die("IMAP error: %s" % e)


def imap_folders(M):
    """-> [(name, delimiter or None)] for every mailbox"""
    typ, data = M.list()
    out = []
    for item in data or []:
        if not isinstance(item, bytes):
            continue
        m = LIST_RE.match(item.decode("utf-8", "replace"))
        if not m:
            continue
        name = m.group("name").strip()
        if name.startswith('"') and name.endswith('"'):
            name = name[1:-1]
        delim = m.group("delim")
        out.append((name, None if delim == "NIL" else delim.strip('"')))
    return out


def tag_folders(folders, tag):
    """the folders a tagged message could be filed in: INBOX, TAG, <anything><delim>TAG"""
    out = ["INBOX"]
    for name, delim in folders:
        if name != "INBOX" and (name == tag or (delim and name.endswith(delim + tag))):
            out.append(name)
    return out


def imap_find(M, folder, token):
    """-> (raw header bytes, message number) of the probe in FOLDER, or (None, 0)"""
    typ, _ = M.select('"%s"' % folder)
    if typ != "OK":
        return None, 0
    typ, data = M.search(None, "SUBJECT", token)
    nums = data[0].split() if typ == "OK" and data and data[0] else []
    if not nums:
        M.close()
        return None, 0
    typ, data = M.fetch(nums[0].decode(), "(BODY.PEEK[HEADER])")
    hdr = b"".join(x[1] for x in data if isinstance(x, tuple))
    return hdr, int(nums[0])


def imap_poll(a, login, pw, tag, token, deadline):
    """-> (folder, header bytes, M) with FOLDER selected and the probe at M.num,
    or (None, None, None).  Looks at INBOX and the tag folders only."""
    while True:
        M = imap_open(a, login, pw)
        for folder in tag_folders(imap_folders(M), tag):
            hdr, num = imap_find(M, folder, token)
            if hdr is not None:
                M.num = num
                return folder, hdr, M
        M.logout()
        if time.time() >= deadline:
            return None, None, None
        time.sleep(min(5, max(0.0, deadline - time.time())))


def imap_cleanup(a, login, pw, M, folder, folders_before):
    """expunge the probe; drop the tag folder again if the probe's delivery made it"""
    notes = []
    M.store(str(M.num), "+FLAGS", "(\\Deleted)")
    M.expunge()
    M.close()
    if folder not in folders_before and folder != "INBOX":
        typ, data = M.select('"%s"' % folder)
        empty = typ == "OK" and data and data[0] == b"0"
        if typ == "OK":
            M.close()
        if empty:
            M.unsubscribe('"%s"' % folder)
            typ, _ = M.delete('"%s"' % folder)
            notes.append("deleted the folder %s the probe created" % folder if typ == "OK"
                         else "could not delete the folder %s the probe created" % folder)
        else:
            notes.append("left folder %s alone (not empty)" % folder)
    M.logout()
    return notes


# ---------------------------------------------------------------------------
# POP3
# ---------------------------------------------------------------------------
def pop_poll(a, login, pw, token, deadline):
    """-> (raw message bytes, number, connection) for the probe in the POP inbox, or (None, 0, None)"""
    while True:
        try:
            if a.no_tls:
                M = poplib.POP3(a.pop_host, a.pop_port, timeout=45)
            else:
                M = poplib.POP3_SSL(a.pop_host, a.pop_port, context=ssl.create_default_context(), timeout=45)
            M.user(login); M.pass_(pw)
            for i in range(1, M.stat()[0] + 1):
                raw = b"\r\n".join(M.retr(i)[1]) + b"\r\n"
                if token.encode() in raw:
                    return raw, i, M
            M.quit()
        except (poplib.error_proto, OSError) as e:
            die("POP3 error: %s" % e)
        if time.time() >= deadline:
            return None, 0, None
        time.sleep(min(5, max(0.0, deadline - time.time())))


def tagged_in(raw, want):
    """-> [header names that carry WANT], from the message headers"""
    msg = email.parser.BytesHeaderParser().parsebytes(raw)
    found = []
    for h in HEADERS:
        for val in msg.get_all(h, []):
            if any(addr.lower() == want.lower() for _, addr in email.utils.getaddresses([str(val)])):
                found.append(h)
                break
    return found


def main():
    ap = argparse.ArgumentParser(description="probe a mail host for plus-address support")
    ap.add_argument("--relay-file", help="cPanel-style relay info (Outgoing/Incoming Server, Username, SMTP Port)")
    ap.add_argument("--pwfile", default="/etc/postfix/sasl_passwd")
    ap.add_argument("--user", help="mailbox login (default: Username from the relay file)")
    ap.add_argument("--base", help="shared address to tag (default: the login)")
    ap.add_argument("--tag", default="probe", help="the TAG to test: base+TAG@domain (default probe)")
    ap.add_argument("--wait", type=int, default=90, help="seconds to wait for delivery (default 90)")
    ap.add_argument("--keep", action="store_true", help="leave the probe message (and folder) in the mailbox")
    ap.add_argument("--no-imap", action="store_true", help="skip the IMAP check (POP inbox only)")
    ap.add_argument("--smtp-host"); ap.add_argument("--smtp-port", type=int)
    ap.add_argument("--pop-host"); ap.add_argument("--pop-port", type=int)
    ap.add_argument("--imap-host"); ap.add_argument("--imap-port", type=int)
    ap.add_argument("--token", help=argparse.SUPPRESS)
    ap.add_argument("--no-tls", action="store_true", help="plain SMTP/POP3/IMAP (testing only)")
    ap.add_argument("--no-auth", action="store_true", help="skip SMTP AUTH only (testing only)")
    a = ap.parse_args()
    socket.setdefaulttimeout(45)

    rf = a.relay_file
    login = a.user or (rf and relay_field(rf, "Username")) or "cwp@u-l.ca"
    a.smtp_host = a.smtp_host or (rf and relay_field(rf, "Outgoing Server")) or "u-l.ca"
    a.pop_host = a.pop_host or (rf and relay_field(rf, "Incoming Server")) or "u-l.ca"
    a.imap_host = a.imap_host or a.pop_host
    a.smtp_port = smtp_port(a.smtp_port, rf and relay_field(rf, "SMTP Port"))
    a.pop_port = a.pop_port or 995
    a.imap_port = a.imap_port or 993
    base = a.base or login
    if base.count("@") != 1 or "+" in base or not re.match(r"^[A-Za-z0-9._-]+$", a.tag):
        die("--base must be a plain address like cwp@u-l.ca and --tag a simple word")
    local, _, dom = base.partition("@")
    addr = "%s+%s@%s" % (local, a.tag, dom)
    token = a.token or uuid.uuid4().hex[:16]
    pw = password(a.pwfile, login)

    print("probe address : %s   (login %s, smarthost %s:%d, pop %s:%d%s)"
          % (addr, login, a.smtp_host, a.smtp_port, a.pop_host, a.pop_port,
             "" if a.no_imap else ", imap %s:%d" % (a.imap_host, a.imap_port)))

    folders_before = []
    if not a.no_imap:                    # what exists before the probe, so only a folder IT created is removed
        M = imap_open(a, login, pw)
        folders_before = [n for n, _ in imap_folders(M)]
        M.logout()

    ok_send, detail = send_probe(a, login, pw, addr, token)
    print("%s  1. smarthost accepts a +tag sender: %s" % ("PASS" if ok_send else "FAIL", detail))
    if not ok_send:
        print("      -> per-user outbound senders won't work as is; keep the shared sender"
              " (omit --plus-users) or ask the host to allow +tag senders.")
        sys.exit(1)

    deadline = time.time() + a.wait
    where, hdr, kind = None, None, None          # kind: "folder" | "inbox"
    iM = pM = None
    pnum = 0
    while where is None:
        if not a.no_imap:
            folder, hdr, iM = imap_poll(a, login, pw, a.tag, token, time.time())    # one pass
            if folder is not None:
                where, kind = "IMAP folder " + folder if folder != "INBOX" else "inbox (via IMAP)", \
                    "folder" if folder != "INBOX" else "inbox"
                ifolder = folder
                break
        raw, pnum, pM = pop_poll(a, login, pw, token, time.time())                  # one pass
        if raw is not None:
            where, kind, hdr = "inbox (via POP3)", "inbox", raw
            break
        if time.time() >= deadline:
            break
        time.sleep(min(5, max(0.0, deadline - time.time())))

    ok_deliver = where is not None
    print("%s  2. mail to %s reaches the mailbox: %s"
          % ("PASS" if ok_deliver else "FAIL", addr,
             where if ok_deliver else "not seen in %ds (INBOX/POP%s)" % (a.wait, "" if a.no_imap else "/IMAP tag folders")))

    ok_route = False
    if ok_deliver:
        if kind == "folder":
            prefix = ifolder[:-len(a.tag)]
            ok_route = True
            print("PASS  3. the folder name is the routing key: %s  (prefix %r)" % (ifolder, prefix))
            print("      -> use  configure-getmail.sh --imap --plus-base %s --plus-users ... --plus-prefix %r"
                  "\n         (pop-pull and POP3 can't see tagged mail on this host)" % (base, prefix))
        else:
            hdrs = tagged_in(hdr, addr)
            ok_route = bool(hdrs)
            print("%s  3. a header names the tagged address: %s"
                  % ("PASS" if ok_route else "FAIL", ", ".join(hdrs) if hdrs else "none of " + "/".join(HEADERS)))
            if ok_route:
                print("      -> tagged mail lands in the inbox: pop-pull --plus-base %s works"
                      " (so does getmail --plus-base/--plus-users, by header)" % base)
            else:
                print("      -> the host strips the tag: neither pop-pull nor getmail can tell users apart.")
        if not a.keep:
            if iM is not None:
                for note in imap_cleanup(a, login, pw, iM, ifolder, folders_before):
                    print("      (%s)" % note)
            elif pM is not None:
                pM.dele(pnum)
                pM.quit()
        else:
            for M in (iM, pM):
                if M is not None:
                    try:
                        M.logout() if isinstance(M, imaplib.IMAP4) else M.quit()
                    except Exception:
                        pass
    sys.exit(0 if (ok_send and ok_deliver and ok_route) else 1)


if __name__ == "__main__":
    main()
