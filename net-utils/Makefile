# net-utils: install the tools where the system finds them.
#
#   make                 what is here and where it would go
#   sudo make install    the command-line tools          -> $(PREFIX)/bin           (any machine)
#   sudo make install-cpbee   the cpbee router parts      (run on cpbee, after `make install`), from ../cmpi-router
#        $(PREFIX)/sbin/upnp-sync-cmrouter     passes UPnP mappings on to the upstream router
#        $(TRAFFIC_DIR)/router.py, router.html the /router web page (the traffic service is restarted)
#      setup-router.sh is not copied: it runs from the repo (~/cmpi-router is a symlink to ../cmpi-router), and
#      `sudo ./bin/setup-router.sh upnp` there installs miniupnpd, the systemd units and the firewall rules itself.
#   make check           syntax of everything, and the tests that need nothing but a shell
#   make diff            repo against the installed copies (what `install` would change)
#   sudo make uninstall  remove what `install` and `install-cpbee` put in place (not setup-router.sh's own work)
#
# Variables: PREFIX (/usr/local), DESTDIR (staging root, for packaging or a dry run), TRAFFIC_DIR (/opt/trafficgraph).

PREFIX      ?= /usr/local
DESTDIR     ?=
TRAFFIC_DIR ?= /opt/trafficgraph

TOOLS     := auth auth-askpass auth-canary identity lan-port netrc-to-tickets traceroute-plus.sh
CPR       := ../cmpi-router
INSTALL   := install

.PHONY: all help install uninstall install-tools install-cpbee uninstall-cpbee check diff

all help:
	@echo "tools     -> $(DESTDIR)$(PREFIX)/bin:  $(TOOLS)"
	@echo "cpbee     -> $(DESTDIR)$(PREFIX)/sbin/upnp-sync-cmrouter, $(DESTDIR)$(TRAFFIC_DIR)/router.{py,html}"
	@echo "make install | install-cpbee | check | diff | uninstall      (see the top of this Makefile)"

install: install-tools

install-tools:
	$(INSTALL) -d $(DESTDIR)$(PREFIX)/bin
	$(INSTALL) -m 755 $(TOOLS) $(DESTDIR)$(PREFIX)/bin/

install-cpbee:
	$(INSTALL) -d $(DESTDIR)$(PREFIX)/sbin
	$(INSTALL) -m 755 $(CPR)/bin/upnp-sync-cmrouter $(DESTDIR)$(PREFIX)/sbin/
	@if [ -d $(DESTDIR)$(TRAFFIC_DIR) ] || [ -n "$(DESTDIR)" ]; then \
	  $(INSTALL) -d $(DESTDIR)$(TRAFFIC_DIR) && \
	  $(INSTALL) -m 644 $(CPR)/traffic/router.py $(CPR)/traffic/router.html $(DESTDIR)$(TRAFFIC_DIR)/ && \
	  if [ -z "$(DESTDIR)" ] && systemctl is-enabled trafficgraph >/dev/null 2>&1; then systemctl restart trafficgraph && echo "trafficgraph restarted"; fi; \
	else echo "$(TRAFFIC_DIR) not found: traffic graphs are not installed here, the /router page files were skipped"; fi

uninstall: uninstall-cpbee
	cd $(DESTDIR)$(PREFIX)/bin && rm -f $(TOOLS)

uninstall-cpbee:
	rm -f $(DESTDIR)$(PREFIX)/sbin/upnp-sync-cmrouter

check:
	@for f in auth-askpass auth-canary lan-port traceroute-plus.sh test/test_lan_port.sh $(CPR)/bin/setup-router.sh $(CPR)/bin/upnp-sync-cmrouter; do bash -n $$f || exit 1; done
	@python3 -c "import ast,sys; [ast.parse(open(f).read(), f) for f in sys.argv[1:]]" $(CPR)/traffic/router.py auth identity netrc-to-tickets
	@bash test/test_lan_port.sh | tail -1

diff:
	@for f in $(TOOLS); do diff -q $$f $(DESTDIR)$(PREFIX)/bin/$$f 2>&1 | sed 's/^/tools: /'; done; true
	@diff -q $(CPR)/bin/upnp-sync-cmrouter $(DESTDIR)$(PREFIX)/sbin/upnp-sync-cmrouter 2>&1 | sed 's/^/sbin: /'; true
	@for f in router.py router.html; do diff -q $(CPR)/traffic/$$f $(DESTDIR)$(TRAFFIC_DIR)/$$f 2>&1 | sed 's/^/page: /'; done; true
