#!/usr/bin/env python3
"""get_mfa_code.py HOST [USER]: print the current 6-digit one-time code (TOTP, RFC 6238) for a host.

The generic form of the old get2fa_code.py: it works for any host, not for one built-in account, and needs no pip
package.  net-login (ssh-mfa, sudo-mfa) calls it whenever a host asks for its "Token:" or "Verification code:".

Where the secret comes from, first hit wins
  1. the vault:        auth totp HOST [USER]       (a record stored with  auth set 2fa@HOST USER --kind totp)
  2. a token file:     $MFA_TOKENS, else ~/.config/mfa/tokens.json, else <this script's folder>/.2fa/tokens.json
                       (the old get2fa_code.py file).  JSON, in any of these shapes (base32 secrets, as the site shows them):
                         {"HOST": "SECRET"}                     one secret per host
                         {"HOST": {"USER": "SECRET", ...}}      one per login on that host
                         {"USER": "SECRET"}                     the old shape: keyed by login; used when USER is given
                       HOST is tried as given and as its short name (before the first dot).

Options
  --no-vault      skip step 1 (also: MFA_NO_VAULT=1)       --digits N   code length (default 6)
  --verify CODE   print nothing; exit 0 if CODE is the current code for HOST [USER], 1 if not, 3 if there is no seed.
                  (With a token file the previous and next code count too; the vault answers with the current one only.)
  --file PATH     use this token file only                 -h, --help
Environment: MFA_AUTH (the auth tool; default `auth` on PATH, else next to this script), MFA_TOKENS (token file),
MFA_NO_VAULT.

Output: the code and a newline on stdout.  Exit 0 on success, 1 if no secret is found, 2 on bad usage.  The secret is
never printed, not even in an error.
"""
import base64
import hashlib
import hmac
import json
import os
import re
import struct
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.realpath(__file__))


def totp(secret, now=None, digits=6, step=30):
    """RFC 6238 TOTP (HMAC-SHA1) of a base32 secret."""
    s = re.sub(r"[\s-]", "", secret).upper()
    s += "=" * (-len(s) % 8)
    key = base64.b32decode(s)
    counter = int((time.time() if now is None else now) // step)
    mac = hmac.new(key, struct.pack(">Q", counter), hashlib.sha1).digest()
    off = mac[-1] & 0x0F
    num = (struct.unpack(">I", mac[off:off + 4])[0] & 0x7FFFFFFF) % (10 ** digits)
    return str(num).zfill(digits)


def from_vault(host, user, digits):
    auth = os.environ.get("MFA_AUTH")
    if not auth:
        auth = "auth"
        side = os.path.join(HERE, "auth")
        if not any(os.access(os.path.join(d, "auth"), os.X_OK) for d in os.environ.get("PATH", "").split(os.pathsep) if d) \
                and os.access(side, os.X_OK):
            auth = side
    cmd = [auth, "totp", host] + ([user] if user else []) + ["--digits", str(digits)]
    try:
        r = subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           timeout=15, universal_newlines=True)
    except (OSError, subprocess.TimeoutExpired):
        return None
    out = r.stdout.strip().splitlines()
    if r.returncode == 0 and out and re.fullmatch(r"\d{%d}" % digits, out[-1].strip()):
        return out[-1].strip()
    return None


def token_files(explicit):
    if explicit:
        return [explicit]
    files = []
    if os.environ.get("MFA_TOKENS"):
        files.append(os.environ["MFA_TOKENS"])
    files.append(os.path.expanduser("~/.config/mfa/tokens.json"))
    files.append(os.path.join(HERE, ".2fa", "tokens.json"))
    return files


def secret_from(data, host, user):
    if not isinstance(data, dict):
        return None
    for key in dict.fromkeys([host, host.split(".")[0]]):
        ent = data.get(key)
        if isinstance(ent, str):
            return ent
        if isinstance(ent, dict):
            if user and isinstance(ent.get(user), str):
                return ent[user]
            if not user and len(ent) == 1:
                only = next(iter(ent.values()))
                if isinstance(only, str):
                    return only
    short = host.split(".")[0]
    for key, ent in data.items():                          # a key with a longer or shorter domain than the host given
        if key.split(".")[0] == short and key != host:
            sub = secret_from({host: ent}, host, user)
            if sub:
                return sub
    if user and isinstance(data.get(user), str):          # the old get2fa_code.py shape
        return data[user]
    return None


def from_file(host, user, explicit):
    for path in token_files(explicit):
        try:
            with open(path, "r") as fh:
                data = json.load(fh)
        except (OSError, ValueError):
            continue
        sec = secret_from(data, host, user)
        if sec:
            return sec
    return None


def main(argv):
    args = []
    digits = 6
    novault = bool(os.environ.get("MFA_NO_VAULT"))
    explicit = None
    verify = None
    it = iter(argv)
    for a in it:
        if a in ("-h", "--help"):
            print(__doc__.strip("\n"))
            return 0
        elif a == "--no-vault":
            novault = True
        elif a == "--digits":
            try:
                digits = int(next(it))
            except (StopIteration, ValueError):
                print("get_mfa_code: --digits needs a number", file=sys.stderr)
                return 2
        elif a == "--verify":
            verify = next(it, None)
            if not verify:
                print("get_mfa_code: --verify needs a code", file=sys.stderr)
                return 2
        elif a == "--file":
            explicit = next(it, None)
            if not explicit:
                print("get_mfa_code: --file needs a path", file=sys.stderr)
                return 2
        elif a.startswith("-") and a != "-":
            print("get_mfa_code: unknown option %s" % a, file=sys.stderr)
            return 2
        else:
            args.append(a)
    if not args or len(args) > 2:
        print("usage: get_mfa_code.py [--no-vault] [--file PATH] [--digits N] HOST [USER]", file=sys.stderr)
        return 2
    host = args[0]
    user = args[1] if len(args) > 1 else ""

    if not novault and not explicit:
        code = from_vault(host, user, digits)
        if code:
            if verify is not None:
                return 0 if hmac.compare_digest(code, verify.strip()) else 1
            print(code)
            return 0
    sec = from_file(host, user, explicit)
    if sec and verify is not None:
        try:
            now = time.time()
            ok = any(hmac.compare_digest(totp(sec, now=now + d * 30, digits=digits), verify.strip()) for d in (-1, 0, 1))
        except (ValueError, TypeError):
            return 1
        return 0 if ok else 1
    if verify is not None and not sec:
        return 3
    if sec:
        try:
            print(totp(sec, digits=digits))
            return 0
        except (ValueError, TypeError):
            print("get_mfa_code: the stored secret for %s is not valid base32" % host, file=sys.stderr)
            return 1
    print("get_mfa_code: no secret for %s%s (vault: %s; token files: %s)"
          % (host, " / " + user if user else "", "skipped" if novault or explicit else "no answer",
             ", ".join(token_files(explicit))), file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
