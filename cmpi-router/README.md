# cmpi: Windows + Debian 13 router (Beelink Mini S)

Hardware: AZW MINI S, Intel N95, 16 GB, 512 GB SSD, UEFI, 1x GbE (Realtek) + Wi-Fi 5 (AC 7265).
Plan: keep Windows 11 (C: shrunk by 64 GB), add Debian 13 in the freed space, Debian is the router.
The router needs a **second Ethernet port**: a USB 3 Gigabit adapter (Realtek RTL8153 or ASIX AX88179 work well, and Debian has drivers).

## Folder layout

    bin/        scripts you run: setup-router.sh (router setup and every subcommand), pull-from-cmpi.sh, prepare-dualboot.ps1,
                Set-HomeNetPolicy.ps1 (for the Windows PCs: metered connection + LAN update sharing)
    traffic/    the traffic graphs web app (server.py, index.html, plan.py, acct-export.py); installed by `bin/setup-router.sh graphs`
    middle/     devices.txt, the fixed addresses used by `bin/setup-router.sh leases`
    Misc/       notes, the Debian ISO, cpbee.docx
    BAK/        copies of files taken before each edit
    HANDOFF.md  running status and decisions;  MIDDLE-PLAN.md  the cutover runbook

On cpbee the same layout lives in ~/cmpi-router, so commands are run as `sudo ./bin/setup-router.sh <mode>` from that folder.

## 1. Windows side (done by `prepare-dualboot.ps1`)
Run from an *Administrator* PowerShell in this folder:

    powershell -ExecutionPolicy Bypass -File .\prepare-dualboot.ps1

It asks before each step: Fast Startup off, shrink C: by 64 GB, write `debian-13.7.0-amd64-netinst.iso`
(SHA-256 verified) to a USB stick (you pick the disk and type ERASE). The Kingston stick currently holds
an Ubuntu 23 installer and will be wiped. If the raw write fails, use Rufus in "DD Image" mode instead.

## 2. Install Debian
1. Plug the stick in, reboot, tap F7 (Beelink boot menu; or Del for BIOS), pick the USB (UEFI).
2. Cable the **onboard port** to your current network so the installer has internet. (You can plug in the USB NIC now too.)
3. "Install" (text mode is fine). Language/keyboard/hostname (`cmpi`).
4. Partitioning: **Guided - use the largest continuous free space**. It reuses the existing 100 MB EFI partition.
   Do not choose "entire disk." Check the summary: Windows partitions must be untouched.
5. Software selection: untick desktop environment, tick **SSH server** and **standard system utilities**.
6. Install GRUB to the EFI partition (default). Debian's installer detects Windows and adds it to the GRUB menu.
7. After reboot GRUB shows Debian and Windows Boot Manager. Check both boot.

If Windows boots straight in without GRUB: BIOS boot order, put "debian" before "Windows Boot Manager".

## 3. Turn Debian into the router
Copy `setup-router.sh` over (scp, or the USB stick's second partition), log in on the console, then:

    sudo ./bin/setup-router.sh        # installs packages, writes config, changes nothing live
    sudo reboot
    sudo ./bin/setup-router.sh check

No USB adapter yet? The script offers a **deferred WAN** mode: any USB Ethernet adapter (matched by bus path) becomes `wan0`.
Once it is plugged in, run `sudo ./bin/setup-router.sh wan` to pin it by MAC address, then reboot.
**Warning:** after the reboot the onboard NIC is the LAN with a DHCP server on it. Do not leave it cabled to your existing router.

Defaults: LAN `192.168.10.0/24` (router .1, DHCP .100-.250), onboard NIC = `lan0`, USB NIC = `wan0` (DHCP from upstream).
Firewall: nftables, drop-by-default inbound, SSH/DNS/DHCP/ping from LAN only, NAT + MSS clamp on WAN.
DNS/DHCP: dnsmasq, upstream DNS from the WAN lease. It uses a different subnet from your current router so you can
test behind it (double NAT) before swapping it in. To take over the real network, change `LAN_SUBNET` to your current one.

UPnP / NAT-PMP for the LAN (Vuze, games): `sudo ./bin/setup-router.sh upnp` (`upnp status`, `upnp off`). miniupnpd listens on lan0 only,
clients may map only their own address and ports 1024-65535, and `bin/upnp-sync-cmrouter` asks the router upstream of wan0 (cmrouter
in TEST/MIDDLE, which must have UPnP on) to forward the same ports to cpbee. Its lan0 ports go in the `lan-port` lists; `lan-port upnp` shows the mappings.

Not included yet (untested follow-ups): IPv6/prefix delegation, WireGuard, Wi-Fi AP, ad blocking, PPPoE (if your ISP needs it).
`setup-router.sh` first ran on Debian on 2026-10-03 (config written, nft ruleset and dnsmasq syntax verified, not yet rebooted into). Read the `check` output carefully after the first reboot. `prepare-dualboot.ps1` parses cleanly but its disk steps are likewise untested.
