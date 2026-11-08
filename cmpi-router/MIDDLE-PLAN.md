# MIDDLE setup: cpbee between your machines and the old router (planned 2026-10-04)

**Goal.** Put cpbee in the path while the fibre stays the internet link, so you can *measure* real per-device usage for a few
weeks before deciding (trim the household, or add a data line) and before the final switch to mobile data.

```
BEFORE (today)                          MIDDLE                                          FINAL
fibre -> old router -> switch ->        fibre -> old router -> [USB GbE] cpbee          mobile-data stick -> cpbee
  cmdesktop, printer, laptop,             [onboard port] -> switch -> cmdesktop,          [onboard port] -> switch -> all wired
  Pi (cmpi), phones on Wi-Fi              printer, laptop                                 machines; old router and cmpi gone
                                         old router keeps: Wi-Fi (phones), cmpi
```

cpbee's onboard port stays `lan0` (192.168.10.0/24, DHCP). The USB Ethernet adapter becomes `wan0` and gets an address from the
old router (192.168.1.x), so this is double NAT. That is fine for measuring and keeps the old router's port-forwards working for cmpi.

## 1. The USB-C adapter and cpbee's missing USB-C port

cpbee only has USB-A ports. Ways around it, best first:

| Option | Cost | Notes |
|---|---|---|
| **USB-C *female* to USB-A *male* adapter** between your adapter and cpbee | about $5-8 | Must be a data adapter, not charge-only. Fine for gigabit. Your adapter's USB-C plug goes into the female end. |
| A native **USB-A gigabit adapter** (Realtek RTL8153 or ASIX AX88179 based, e.g. TP-Link UE300, UGREEN) | about $15-25 | One less connector in the chain, so the most reliable. Worth it if the adapter chain is flaky. |

* **Linux support is already there.** cpbee's kernel has `r8152` (Realtek 8152/8153/8156), `ax88179_178a`, `cdc_ncm`, `cdc_ether`,
  `lan78xx`, and `firmware-realtek` is installed. To see the chip tomorrow: plug the adapter into the laptop and run
  `Get-NetAdapter | Select Name,InterfaceDescription` (Realtek USB GbE / ASIX AX88179 / USB 2.5GbE are all fine), or plug it into
  cpbee and run `lsusb`.
* Plug it into a **blue (USB 3) port** if cpbee has one; the phone can sit in any port, it is unplugged during MIDDLE anyway.
* **Naming conflict, now handled:** `wan0` used to mean "any USB network device", so the phone tether and the adapter would fight over
  the name. `sudo ./bin/setup-router.sh wan` now refuses when two are plugged in, lists them, and otherwise pins `wan0` to the adapter by MAC.
  `sudo ./bin/setup-router.sh wan any` goes back to the any-USB-device rule for FINAL (phone or data stick).

## 2. Things I need from you (they change the steps)

1. **How is the wired side cabled today?** I assume: old router -> one switch -> cmdesktop + printer + laptop. If so MIDDLE is one cable
   move (the switch's uplink goes from the old router to cpbee's onboard port), and the old router gets one freed LAN port for the adapter.
2. **Where do cmpi (Pi) and cpvax live?** If they plug into that same switch they would move behind cpbee too, and the Pi has a fixed
   192.168.1.75, which would break. The Pi should stay on the old router (a router port or a separate small switch). Plan: it stays put and is
   reached from the new LAN through cpbee's NAT as 192.168.1.75 (DNS name added below). cpvax (192.168.1.30): is it a VM on a PC, or on the Pi?
3. **Does the old router have a free LAN port, and can you reserve a DHCP address on it?** (Reserving one for the adapter's MAC keeps cpbee's
   WAN address stable, useful later for port-forwards; 192.168.1.80 is free now that the onboard MAC moved.)
4. The three carrier questions from earlier (does a data/USB-SIM line add its own high-speed data, price, post-pool speed, hotspot limit).

## 3. Prepare tonight (nothing here needs the adapter; all of it is reversible)

```bash
cd ~/cmpi-router
sudo ./bin/setup-router.sh graphs                          # installs the newest graphs, plan and alert code
sudo ./bin/setup-router.sh plan --gb 199.76 --day 11 --used 14.87     # alert email: see 3a below
sudo ./bin/setup-router.sh leases                          # fixed addresses + names from middle/devices.txt
VR180_HOSTS="vr180=192.168.123.1 mesh,meshvs8875-1=192.168.123.101 cmpi=192.168.1.75" sudo -E ./bin/setup-router.sh dns
```

* `middle/devices.txt` holds the three wired machines (cmdesktop .77, cmlaptop .73 = its *wired* MAC, cmprinter .66; the last octet matches
  the old numbering and all are outside the DHCP pool). **Check the MACs against the old router's client list first.** The printer and desktop
  MACs come from your hosts file and I have not been able to confirm them.
* `leases` also gives every machine its name through DNS (`cmdesktop`, `cmdesktop.lan`), and the graphs page uses those names.
* Windows `hosts` files (cmlaptop at least): delete or update the stale lines. They still map `cpbee`, `cmdesktop`, `cmlaptop`, `cmprinter`
  to 192.168.1.x, and Windows reads that file before DNS (this is why `ssh cpbee` timed out earlier). Suggested lines, or just delete the old ones:
  `192.168.10.1 cpbee` (optional), `192.168.1.75 cmpi` (if you keep it in the file; DNS now also answers for it).
* **Printer:** Windows normally talks to a printer by IP (192.168.1.66). After the move it is 192.168.10.66, so edit the printer's port on each
  PC (Printer properties > Ports > Configure port) or re-add it by the name `cmprinter`.
* Windows metered flag: cmlaptop is already marked metered. During MIDDLE the real link is the fibre, so this only defers updates and pauses
  OneDrive for no benefit; run `Set-HomeNetPolicy.ps1 -Undo` there if that gets in the way, and re-apply for FINAL.

### 3a. Alert email through the u-l.ca relay (optional, any time; needs no mail system on cpbee)

1. In HostUpon cPanel create a mailbox for cpbee, e.g. `cpbee@u-l.ca`, with its own password (so it can be revoked without touching the laptop's relay login).
2. Look up the outgoing server in cPanel > Email Accounts > Connect Devices ("Mail Client Manual Settings"); typically `mail.u-l.ca`, port 587 (STARTTLS) or 465 (SSL).
3. On cpbee:

```bash
sudo ./bin/setup-router.sh plan --smtp-host mail.u-l.ca --smtp-security starttls --smtp-user cpbee@u-l.ca --smtp-password-prompt --email you@example.com
sudo ./bin/setup-router.sh plan --test-alert
```

The password is typed at a hidden prompt and stored only in `/etc/trafficgraph/smtp-password` (root and the service, mode 0640). It is not in `config.json`, the command line, the logs or this folder. If the test reports a certificate hostname mismatch, use the host name that appears in the server certificate (shown in the same cPanel page) rather than turning verification off.

## 4. Cutover (about 30-45 minutes; do it when nobody needs the internet)

| # | Step | Expect |
|---|---|---|
| 1 | Unplug the **phone** from cpbee. (Your ssh from the laptop over the direct cable still works.) | cpbee loses internet; `wan0` disappears |
| 2 | Connect the adapter to cpbee (through the C-to-A adapter). `lsusb` and `ip -br link` | a new interface such as `enx...`; driver `r8152` or `ax88179_178a` |
| 3 | `sudo ./bin/setup-router.sh wan` then `sudo reboot` | prints the MAC and driver it pinned; after boot the adapter is `wan0` |
| 4 | Plug the adapter's Ethernet cable into a free LAN port on the **old router** | `ip -br addr show wan0` shows 192.168.1.x, default route via 192.168.1.254 |
| 5 | `sudo ./bin/setup-router.sh check` | all ok; the new `[info]` line says wan0 is not a public address (double NAT) |
| 6 | (Old router) reserve an address for the adapter's MAC, e.g. 192.168.1.80 | stable WAN address |
| 7 | Move the **switch's uplink** from the old router to cpbee's **onboard port**. Never connect the switch to both at once | wired machines lose the link for a moment |
| 8 | On each PC renew the address (`ipconfig /renew`, or reboot) | cmdesktop 192.168.10.77, cmlaptop .73, printer .66 |
| 9 | From a PC: `nslookup cmdesktop 192.168.10.1`, `nslookup cmpi 192.168.10.1`, open http://cpbee.lan/ | names resolve; the Devices card lists them by name |
| 10 | Fix the printer port on each PC; test a print; check one machine can reach cmpi (`ping 192.168.1.75`) | works through cpbee's NAT |

Phones keep using the old router's Wi-Fi throughout, and the Pi keeps its inbound port-forwards (mail, web) exactly as they are now.

## 5. What to watch during MIDDLE

* **Devices card** (by 7 days / 30 days): which machine uses what. That answers "what do we trim".
* **Gap to the fibre meter.** At the end of a billing month, the carrier's fibre total minus cpbee's WAN total is everything *not* behind cpbee:
  the phones on Wi-Fi, the Pi, anything else on the old router. The phones' share is what moves onto the mobile pool in FINAL.
* **Plan meter:** keep `--gb 199.76 --day 11` to see the household against today's pool, and try `plan --gb 300` (without `--used`) for the
  "if a third line adds ~100 GB" case. From October 11 the carrier cycle restarts and the old offset expires on its own.
* The WAN card still says "Metered" in MIDDLE. It is not true until FINAL; ignore it.
* Suggested checkpoints: after a week (look for surprises), after a full cycle (Nov 10).

## 6. Rollback (5 minutes, no data lost)

1. Move the switch's uplink back to the old router; renew addresses on the PCs (they get 192.168.1.x again from the old router).
2. Unplug the adapter. If you want the phone tether on cpbee again: `sudo ./bin/setup-router.sh wan any`, reboot, plug the phone in.
3. Put the Windows hosts lines back if you changed them.

## 7. After MIDDLE (not part of this plan)

FINAL needs: the decision on trimming vs a data line, `sudo ./bin/setup-router.sh wan any` for the stick, the Windows script on every PC, cmpi's
services moved to cpbee, and an answer for inbound services behind mobile-data NAT (mail, web, dyndns) because they cannot be reached from outside.
