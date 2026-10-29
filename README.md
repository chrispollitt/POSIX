# POSIX

Portable shell/Python tooling for Unix-like systems (Linux, macOS, the BSDs, Cygwin).

| project | what |
|---|---|
| [mail-setup](mail-setup/) | set up GNU Mailutils, Postfix, Dovecot, and pop-pull or getmail on a master host, or a sendmail shim on thin clients, with unit + end-to-end tests |
| [chat-setup](chat-setup/) | run an Ergo IRC server for the LAN (TLS, NickServ accounts, systemd, firewall), e.g. to test tvmail's chat, and set tvmail up to use it |
| [web-ttyd](web-ttyd/) | serve console apps (maze4, bidet) in a browser tab through ttyd and nginx, in a desktop-style window frame, with SIXEL |
| [net-utils/lan-port](net-utils/lan-port) | open, close and audit the LAN ports of a cmpi-router box (cpbee) through its port lists: one call for every project (chat-setup, mail-setup and web-ttyd use it; tests: `net-utils/test_lan_port.sh`) |
