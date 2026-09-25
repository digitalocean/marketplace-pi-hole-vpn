# Changelog

All notable changes to this Marketplace 1-Click image are documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) principles.

## [Unreleased] — 2026-09-24 modernization

### Added

- **Ubuntu 26.04 LTS** base image (`ubuntu-26-04-x64`), sized for `s-1vcpu-1gb`.
- **Unbound** recursive DNS, configured per the [Pi-hole Unbound guide](https://docs.pi-hole.net/guides/dns/unbound/), listening on `127.0.0.1#5335` only.
- **Pi-hole v6** baked at Packer build time with exclusive upstream `127.0.0.1#5335` (no public resolvers).
- **Host DNS via local Pi-hole**: systemd-resolved drop-in (`DNS=127.0.0.1`, `Domains=~.`) so the Droplet does not use DigitalOcean DHCP DNS.
- **Pi-hole `listeningMode = LOCAL`** so the host and VPN clients can resolve through Pi-hole while UFW still blocks public DNS/HTTP.
- **Default blocklists** seeded into `gravity.db` at image build (`files/pihole/blocklists.txt` + `scripts/pihole-adlists.sh`).
- **`/root/dns-troubleshoot.sh`** (`on` / `off` / `status`) to toggle Unbound verbosity and Pi-hole query logging, with directions for viewing logs.
- **UFW hardening**: deny incoming by default, rate-limit SSH (`22/tcp`), allow WireGuard (`51820/udp`), no public `53`/`80`/`443`.
- **fail2ban** with `sshd` jail (`banaction = ufw`, `maxretry=5`, `bantime=1h`).
- **sshd hardening drop-in** (`PasswordAuthentication no`, idle timeouts, tightened forwarding).
- **`/root/wg-mgmt/`** named peer lifecycle: `add-wg-peer.sh`, `remove-wg-peer.sh`, `list-wg-peers.sh` (+ `peers.csv` / `clients/`).
- Sysctl hardening / forwarding (via `scripts/system-setup.sh`), unused-service trim, unattended-upgrades.
- Packer plugin pin `digitalocean/digitalocean` ≥ `1.4.1`; GitHub Actions `packer validate`; Dependabot for Packer/Terraform/Actions.
- `Makefile` targets: `update-scripts`, `validate`.

### Changed

- Software is **baked at Packer build**; first boot only generates WireGuard keys, MotD QR, Pi-hole admin password, and host resolver finalize.
- WireGuard MotD offers a **single road-warrior** QR per client (`AllowedIPs = 0.0.0.0/0, ::/0`); DNS-only tunnel profile removed.
- WireGuard **tunnel addresses are IPv4-only** (`10.2.53.0/24`).
- Endpoint selection prefers public **IPv4 / Floating IP**; IPv6 only if no usable IPv4.
- Pi-hole **query logging off by default** (enable via `/root/dns-troubleshoot.sh on`).
- Pi-hole **admin UI bound to `10.2.53.1:80`** only; Unbound/Pi-hole configure steps hard-fail if upstream or service is wrong.
- Vendored Marketplace scripts refreshed from [marketplace-partners](https://github.com/digitalocean/marketplace-partners) (`90-cleanup` / `99-img-check`).
- README / droplet MotD / `/root/README` updated for the new architecture.

### Removed

- Debian 11 / first-boot heavy install path (packages no longer installed only on first boot).
- Dual DNS-only + Full VPN QR pair.
- IPv6 WireGuard tunnel addresses (`fc10:253::/32`) and matching UFW `before6` NAT block.
- Public exposure expectations for Pi-hole DNS/UI (VPN-only by design).

### Security

- Public DNS and HTTP/HTTPS to Pi-hole remain closed on the host firewall.
- SSH gated during first-boot setup (`ssh-lock` / `ssh-unlock`) with UFW rate limiting and fail2ban on sshd.
- Managed adlist rows are tagged `Managed by marketplace-pi-hole-vpn` in the Admin UI.

### Default blocklists (baked)

See `files/pihole/blocklists.txt`:

- Steven Black hosts
- Cameleon hosts
- Disconnect simple tracking / ad / malvertising
- AdmiraList
- URLhaus hostfile
- Firebog Prigent-Crypto
- Phishing Army extended

### Migration notes for operators

- Rebuild the Packer snapshot to pick up these changes; existing Droplets from older images are not auto-upgraded.
- After deploy: SSH, scan the Full VPN QR, open `http://10.2.53.1/admin` (or `http://pi.hole/admin`) over the VPN.
- Refresh gravity periodically with `pihole -g`.
- Generate additional clients with `/root/wg-mgmt/add-wg-peer.sh <name>` (preferred), or `/root/regen-vpn-keys.sh <N>` to rotate **all** peers.
