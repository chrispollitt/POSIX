# POSIX

Portable shell/Python tooling for Unix-like systems (Linux, macOS, the BSDs, Cygwin).

| project | what |
|---|---|
| [mail-setup](mail-setup/) | set up GNU Mailutils, Postfix, Dovecot, and pop-pull or getmail on a master host, or a sendmail shim on thin clients, with unit + end-to-end tests |
| [chat-setup](chat-setup/) | run an Ergo IRC server for the LAN (TLS, NickServ accounts, systemd, firewall), e.g. to test tvmail's chat, and set tvmail up to use it |
| [web-ttyd](web-ttyd/) | serve console apps (maze4, bidet) in a browser tab through ttyd and nginx, in a desktop-style window frame, with SIXEL |
| [net-utils/lan-port](net-utils/lan-port) | open, close and audit the LAN ports of a cmpi-router box (cpbee) through its port lists: one call for every project (chat-setup, mail-setup and web-ttyd use it; tests: `net-utils/test/test_lan_port.sh`) |
| [net-utils/netrc-to-tickets](net-utils/netrc-to-tickets) | move logins from ~/.netrc to ~/.mu-tickets, which names the protocol (imaps, smtp, irc, https ...) and is the file tvmail, tvchat and tvcal read first: a known port names the protocol, portless entries and existing `*://` tickets ask (several names allowed: imaps,smtp), bare hosts get .cmnet, backs both files up, never prints a password (tests: `net-utils/test/test_netrc_to_tickets.py`) |  <!-- allowlist secret -->
| [net-utils/identity](net-utils/identity) | who is who: one plain list of the logins a person uses on each service (`chris  irc@irc.libera.chat  chris-pollitt  admin  # why`), asked by login/person/admins and audited by `check` against ~/.netrc, ~/.mu-tickets and the tvmail, tvchat, tvcal and Floyd configurations; no passwords (tests: `net-utils/test/test_identity.py`) |
| [net-utils/auth](net-utils/auth) | the LAN's password vault on cpbee (gpg-encrypted, unlocked once with `auth unlock`), asked from any machine over ssh: `auth get imaps cpbee`, `set`, `import netrc|tickets`, `render tickets|netrc` (writes ~/.mu-tickets and ~/.netrc between BEGIN/END auth lines, rest untouched), `check` against `identity`; phase 1 of the auth-manager; installed by `net-utils/auth-on-cpbee.sh` (tests: `net-utils/test/test_auth.py`) |
