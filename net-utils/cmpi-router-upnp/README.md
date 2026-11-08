# cmpi-router: UPnP for the LAN

Copies of the cmpi-router files changed to add UPnP / NAT-PMP on cpbee, with the upstream router (cmrouter) kept in step.
The working copy lives in `~/cmpi-router` on cpbee (not a git repository); these are snapshots of it, same relative paths.

| File | What changed |
|---|---|
| `bin/setup-router.sh` | new `upnp [on\|off\|status]` mode; `write_nft` adds the miniupnpd chains and the SSDP-answer rule when `/etc/router-setup/upnp` exists; `nft_load` restarts miniupnpd after a ruleset reload |
| `bin/upnp-sync-cmrouter` | mirrors miniupnpd's mappings onto the router upstream of wan0 (installed to `/usr/local/sbin`) |
| `traffic/router.py`, `traffic/router.html` | the `/router` page: UPnP status and the live mappings |

Install on cpbee: `sudo ./bin/setup-router.sh upnp`; the page files go to `/opt/trafficgraph/` (`sudo systemctl restart trafficgraph`).
`lan-port upnp` (in `../lan-port`) shows the mappings. See `../README.md`.
