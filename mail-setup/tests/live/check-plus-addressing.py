#!/usr/bin/env python3
"""check-plus-addressing.py - does YOUR mail host support plus-addresses?

NOT part of run-tests.sh: this one talks to the real servers.  Run it once
before turning on --plus-users / --plus-base, to settle the two things the
mail-setup scripts can't know about your ISP / web host (e.g. cPanel Exim):

  1. does the smarthost accept the envelope sender  cwp+chris@u-l.ca  when you
     log in as cwp@u-l.ca?                              (outbound per-user senders)
  2. does mail to  cwp+chris@u-l.ca  land in the cwp@u-l.ca mailbox, and which
     header names the tagged address, so pop-pull can route it?  (inbound)

It sends one probe message FROM cwp+TAG@domain TO cwp+TAG@domain through the
smarthost (SMTP submission, STARTTLS, AUTH), then polls the mailbox over POP3S
for it, reports which of Delivered-To / X-Original-To / To / Cc carried the
tagged address, and deletes the probe again (--keep to leave it).

    check-plus-addressing.py --relay-file smtp-relay.txt [--tag chris]

The password is read from Postfix's sasl_passwd (--pwfile), like pop-pull.
Exit status: 0 = both fine, 1 = a check failed, 2 = couldn't run.
"""
import argparse, email, email.parser, email.utils, os, re, smtplib, ssl, sys, time, uuid, poplib

HEADERS = ("Delivered-To", "X-Original-To", "To", "Cc")


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
        s = smtplib.SMTP(a.smtp_host, a.smtp_port, timeout=45)
        try:
            if not a.no_tls:
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
        return False, "SMTP error: %s" % e
    return (not refused), ("recipient refused: %s" % refused if refused else "accepted %s as sender and recipient" % addr)


def find_probe(a, login, pw, token):
    """poll POP3 for the probe -> (message_bytes or None, number, popconn)"""
    deadline = time.time() + a.wait
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
    ap.add_argument("--keep", action="store_true", help="leave the probe message in the mailbox")
    ap.add_argument("--smtp-host"); ap.add_argument("--smtp-port", type=int)
    ap.add_argument("--pop-host"); ap.add_argument("--pop-port", type=int)
    ap.add_argument("--token", help=argparse.SUPPRESS)
    ap.add_argument("--no-tls", action="store_true", help="plain SMTP/POP3 (testing only)")
    ap.add_argument("--no-auth", action="store_true", help="skip SMTP AUTH only (testing only)")
    a = ap.parse_args()

    rf = a.relay_file
    login = a.user or (rf and relay_field(rf, "Username")) or "cwp@u-l.ca"
    a.smtp_host = a.smtp_host or (rf and relay_field(rf, "Outgoing Server")) or "u-l.ca"
    a.pop_host = a.pop_host or (rf and relay_field(rf, "Incoming Server")) or "u-l.ca"
    a.smtp_port = a.smtp_port or int((rf and re.sub(r"\D", "", relay_field(rf, "SMTP Port") or "") or "0") or 587)
    if a.smtp_port == 465:
        a.smtp_port = 587               # STARTTLS submission, like configure-sendmail-relay.sh
    a.pop_port = a.pop_port or 995
    base = a.base or login
    if base.count("@") != 1 or "+" in base or not re.match(r"^[A-Za-z0-9._-]+$", a.tag):
        die("--base must be a plain address like cwp@u-l.ca and --tag a simple word")
    local, _, dom = base.partition("@")
    addr = "%s+%s@%s" % (local, a.tag, dom)
    token = a.token or uuid.uuid4().hex[:16]
    pw = password(a.pwfile, login)

    print("probe address : %s   (login %s, smarthost %s:%d, pop %s:%d)"
          % (addr, login, a.smtp_host, a.smtp_port, a.pop_host, a.pop_port))
    ok_send, detail = send_probe(a, login, pw, addr, token)
    print("%s  1. smarthost accepts a +tag sender: %s" % ("PASS" if ok_send else "FAIL", detail))
    if not ok_send:
        print("      -> per-user outbound senders won't work as is; keep the shared sender"
              " (omit --plus-users) or ask the host to allow +tag senders.")

    raw, num, M = find_probe(a, login, pw, token) if ok_send else (None, 0, None)
    ok_deliver = raw is not None
    if ok_send:
        print("%s  2. mail to %s reaches the mailbox%s"
              % ("PASS" if ok_deliver else "FAIL", addr, "" if ok_deliver else " (not seen in %ds)" % a.wait))
    ok_hdr = False
    if ok_deliver:
        hdrs = tagged_in(raw, addr)
        ok_hdr = bool(hdrs)
        print("%s  3. a header names the tagged address: %s"
              % ("PASS" if ok_hdr else "FAIL", ", ".join(hdrs) if hdrs else "none of " + "/".join(HEADERS)))
        if not ok_hdr:
            print("      -> pop-pull / getmail can't tell the users apart on this host.")
        if not a.keep:
            M.dele(num)
        M.quit()
    elif M is not None:
        M.quit()
    sys.exit(0 if (ok_send and ok_deliver and ok_hdr) else 1)


if __name__ == "__main__":
    main()
