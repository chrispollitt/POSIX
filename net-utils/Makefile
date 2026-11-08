# net-utils: install the tools where the system finds them.
#
#   make                 what is here and where it would go
#   sudo make install    the command-line tools         -> $(PREFIX)/bin            (any machine)
#   sudo make install-cpbee   the cpbee router parts     (run on cpbee, after `make install`)
#        $(PREFIX)/sbin/upnp-sync-cmrouter     passes UPnP mappings on to the upstream router
#        $(TRAFFIC_DIR)/router.py, router.html the /router web page (the traffic service is restarted)
#        $(CMPI_ROUTER)/bin/setup-router.sh    the router setup script; lan-port looks for it there
#                                              (it then installs miniupnpd etc. itself:  sudo $(CMPI_ROUTER)/bin/setup-router.sh upnp)
#   make check           syntax of everything, and the tests that need nothing but a shell
#   make diff            repo against the installed copies (what `install` would change)
#   make pull            copy the live cpbee files back into the repo (they are edited in place on cpbee)
#   sudo make uninstall  remove what `install` and `install-cpbee` put in place (not setup-router.sh's own work)
#
# Variables: PREFIX (/usr/local), DESTDIR (staging root, for packaging or a dry run), CMPI_ROUTER (the cmpi-router
# checkout of the user running sudo, else of the current user), TRAFFIC_DIR (/opt/trafficgraph).

PREFIX      ?= /usr/local
DESTDIR     ?=
TRAFFIC_DIR ?= /opt/trafficgraph
OWNER_HOME  := $(shell getent passwd $${SUDO_USER:-$$(id -un)} | cut -d: -f6)
CMPI_ROUTER ?= $(OWNER_HOME)/cmpi-router

TOOLS     := auth identity lan-port netrc-to-tickets traceroute-plus.sh
UPNP      := cmpi-router-upnp
INSTALL   := install

.PHONY: all help install uninstall install-tools install-cpbee uninstall-cpbee check diff pull

all help:
	@echo "tools     -> $(DESTDIR)$(PREFIX)/bin:  $(TOOLS)"
	@echo "cpbee     -> $(DESTDIR)$(PREFIX)/sbin/upnp-sync-cmrouter, $(DESTDIR)$(TRAFFIC_DIR)/router.{py,html}, $(DESTDIR)$(CMPI_ROUTER)/bin/setup-router.sh"
	@echo "make install | install-cpbee | check | diff | pull | uninstall      (see the top of this Makefile)"

install: install-tools

install-tools:
	$(INSTALL) -d $(DESTDIR)$(PREFIX)/bin
	$(INSTALL) -m 755 $(TOOLS) $(DESTDIR)$(PREFIX)/bin/

install-cpbee:
	$(INSTALL) -d $(DESTDIR)$(PREFIX)/sbin
	$(INSTALL) -m 755 $(UPNP)/bin/upnp-sync-cmrouter $(DESTDIR)$(PREFIX)/sbin/
	@if [ -d $(DESTDIR)$(TRAFFIC_DIR) ] || [ -n "$(DESTDIR)" ]; then \
	  $(INSTALL) -d $(DESTDIR)$(TRAFFIC_DIR) && \
	  $(INSTALL) -m 644 $(UPNP)/traffic/router.py $(UPNP)/traffic/router.html $(DESTDIR)$(TRAFFIC_DIR)/ && \
	  if [ -z "$(DESTDIR)" ] && systemctl is-enabled trafficgraph >/dev/null 2>&1; then systemctl restart trafficgraph && echo "trafficgraph restarted"; fi; \
	else echo "$(TRAFFIC_DIR) not found: traffic graphs are not installed here, the /router page files were skipped"; fi
	$(INSTALL) -d $(DESTDIR)$(CMPI_ROUTER)/bin
	$(INSTALL) -m 755 $(UPNP)/bin/setup-router.sh $(UPNP)/bin/upnp-sync-cmrouter $(DESTDIR)$(CMPI_ROUTER)/bin/
	@if [ -z "$(DESTDIR)" ] && [ -n "$$SUDO_USER" ]; then chown $$SUDO_USER: $(CMPI_ROUTER)/bin/setup-router.sh $(CMPI_ROUTER)/bin/upnp-sync-cmrouter; fi

uninstall: uninstall-cpbee
	cd $(DESTDIR)$(PREFIX)/bin && rm -f $(TOOLS)

uninstall-cpbee:
	rm -f $(DESTDIR)$(PREFIX)/sbin/upnp-sync-cmrouter

check:
	@for f in lan-port traceroute-plus.sh test/test_lan_port.sh $(UPNP)/bin/setup-router.sh $(UPNP)/bin/upnp-sync-cmrouter; do bash -n $$f || exit 1; done
	@python3 -m py_compile $(UPNP)/traffic/router.py auth identity netrc-to-tickets && rm -rf $(UPNP)/traffic/__pycache__ __pycache__
	@bash test/test_lan_port.sh | tail -1

diff:
	@for f in $(TOOLS); do diff -q $$f $(DESTDIR)$(PREFIX)/bin/$$f 2>&1 | sed 's/^/tools: /'; done; true
	@diff -q $(UPNP)/bin/upnp-sync-cmrouter $(DESTDIR)$(PREFIX)/sbin/upnp-sync-cmrouter 2>&1 | sed 's/^/sbin: /'; true
	@for f in router.py router.html; do diff -q $(UPNP)/traffic/$$f $(DESTDIR)$(TRAFFIC_DIR)/$$f 2>&1 | sed 's/^/page: /'; done; true
	@for f in setup-router.sh upnp-sync-cmrouter; do diff -q $(UPNP)/bin/$$f $(DESTDIR)$(CMPI_ROUTER)/bin/$$f 2>&1 | sed 's/^/cmpi-router: /'; done; true

pull:
	cp -p $(CMPI_ROUTER)/bin/setup-router.sh $(CMPI_ROUTER)/bin/upnp-sync-cmrouter $(UPNP)/bin/
	cp -p $(CMPI_ROUTER)/traffic/router.py $(CMPI_ROUTER)/traffic/router.html $(UPNP)/traffic/
	@git status --short $(UPNP) 2>/dev/null || true
