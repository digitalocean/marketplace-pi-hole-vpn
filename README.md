# Pi-hole VPN

**Self-hosted WireGuard VPN with Pi-hole ad blocking and Unbound recursive DNS** on Ubuntu 26.04 LTS — a DigitalOcean Marketplace 1-Click image.

You get an on-demand VPN you own and manage, with network-wide blocking and recursive DNS that does **not** depend on public resolvers (Cloudflare, Google, OpenDNS, or DigitalOcean DHCP DNS).

```text
VPN client  →  Pi-hole  →  Unbound (127.0.0.1#5335)  →  root / TLD / auth servers
Droplet host →  Pi-hole (127.0.0.1 via systemd-resolved)
```

See the [Pi-hole Unbound guide](https://docs.pi-hole.net/guides/dns/unbound/).

Release history: [`CHANGELOG.md`](CHANGELOG.md).

---

## Quick start (Marketplace)

1. Create a Droplet from the [Pi-hole VPN 1-Click](https://marketplace.digitalocean.com/apps/pi-hole-vpn) (recommended size: **1 GB** / `s-1vcpu-1gb`).
2. Wait ~1–2 minutes for first-boot setup (SSH may show “Please wait while we perform initial setup…”).
3. SSH in: `ssh root@YOUR_DROPLET_IP`
4. Scan the road-warrior WireGuard QR code in the MotD with the [WireGuard app](https://www.wireguard.com/install/).
5. Connect the VPN, then open the Pi-hole admin UI:
   - `http://pi.hole/admin` or `http://10.2.53.1/admin`
6. Admin password is printed in the MotD and saved in `/root/.pihole_admin_password` and `/root/README`.

Floating / Reserved IP: assign it to the Droplet, then SSH and scan the QR (Endpoint prefers public IPv4 / Floating IP). Edit the client `Endpoint` manually if needed.

---

## What’s included

| Component | Role |
|-----------|------|
| **WireGuard** | Road-warrior VPN (`51820/udp`); MotD QR for clients |
| **Pi-hole v6** | Ad / tracker / malware blocking; admin UI over VPN only |
| **Unbound** | Local recursive resolver (`127.0.0.1#5335`) with DNSSEC hardening |
| **UFW** | Host firewall: SSH rate-limit, WG open, DNS/HTTP not public |
| **fail2ban** | Bans repeated SSH auth failures via UFW (`sshd` jail) |
| **systemd-resolved** | Host uses Pi-hole at `127.0.0.1` (`Domains=~.`) |

Packages are **pre-baked** into the snapshot. First boot generates WireGuard keys, MotD QR, Pi-hole password, and finalizes host DNS.

---

## Firewall

**On-Droplet (UFW + fail2ban)**

- Allow / limit: TCP `22` (SSH, rate-limited)
- Allow: UDP `51820` (WireGuard)
- Also accepts UDP `1194` and `123` redirected to WireGuard (see `/root/README`)
- Deny public DNS (`53`) and HTTP/HTTPS to Pi-hole
- **fail2ban** `sshd` jail: after repeated failures, bans the source IP through UFW (`maxretry=5`, `findtime=10m`, `bantime=1h`)

```bash
fail2ban-client status sshd
# Unban if you lock yourself out from another host:
# fail2ban-client set sshd unbanip A.B.C.D
```

**Recommended DigitalOcean Cloud Firewall (defense in depth)**

| Direction | Protocol | Port | Purpose |
|-----------|----------|------|---------|
| Inbound | TCP | 22 | SSH |
| Inbound | UDP | 51820 | WireGuard |
| Inbound | UDP | 1194 / 123 | Optional alternate WG ports |

Pi-hole DNS and the admin UI are **VPN-only**.

---

## WireGuard clients

### First client

SSH in and scan the MotD QR (road warrior: all traffic via the Droplet). Config uses:

- Tunnel: `10.2.53.0/24` (IPv4-only addresses)
- DNS: `10.2.53.1` (Pi-hole)
- `AllowedIPs = 0.0.0.0/0, ::/0`

### More clients / regenerate keys

Add or remove a single device without touching the others:

```bash
/root/wg-mgmt/add-wg-peer.sh phone
/root/wg-mgmt/list-wg-peers.sh
/root/wg-mgmt/remove-wg-peer.sh phone
```

Configs are stored under `/root/wg-mgmt/clients/`; metadata in `/root/wg-mgmt/peers.csv`. MotD peers are named `client1`, `client2`, …

To rotate **all** keys:

```bash
/root/regen-vpn-keys.sh 3
```

This **regenerates all peers** and prints new QR codes. Every existing client must re-scan or update its config. Prefer `add-wg-peer.sh` / `remove-wg-peer.sh` for day-to-day changes. Details: `cat /root/README`.

---

## Pi-hole admin & blocklists

### Admin UI

Connect to the VPN first, then visit `http://10.2.53.1/admin` or `http://pi.hole/admin`. The admin UI binds only to `10.2.53.1` (not the public interface).

### Default blocklists

These URLs are inserted into the Pi-hole `adlist` table at **image build** (comment: `Managed by marketplace-pi-hole-vpn`). Source of truth in the repo: [`files/pihole/blocklists.txt`](files/pihole/blocklists.txt).

| List |
|------|
| https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts |
| http://sysctl.org/cameleon/hosts |
| https://s3.amazonaws.com/lists.disconnect.me/simple_tracking.txt |
| https://s3.amazonaws.com/lists.disconnect.me/simple_ad.txt |
| https://raw.githubusercontent.com/jkrejcha/AdmiraList/master/AdmiraList.txt |
| https://urlhaus.abuse.ch/downloads/hostfile/ |
| https://s3.amazonaws.com/lists.disconnect.me/simple_malvertising.txt |
| https://v.firebog.net/hosts/Prigent-Crypto.txt |
| https://phishing.army/download/phishing_army_blocklist_extended.txt |

### Manage lists in the Pi-hole UI

1. Connect via WireGuard.
2. Open **Admin → Lists** (Adlists).
3. Enable / disable / delete lists, or **Add a new adlist** with any hosts-file URL.
4. Click **Update Gravity** (or run `pihole -g` over SSH) to download and rebuild.

### Manage lists from SSH

```bash
# Rebuild gravity from current adlists
pihole -g

# Re-apply managed URLs from the image (idempotent; then rebuild)
/usr/local/sbin/pihole-adlists.sh

# Insert URLs only (no gravity rebuild)
/usr/local/sbin/pihole-adlists.sh --no-gravity
```

Managed list file on the Droplet: `/usr/local/share/pihole-vpn/blocklists.txt`.

---

## Host DNS & troubleshooting

The Droplet itself resolves through local Pi-hole (`127.0.0.1`), not DigitalOcean’s resolvers.

Query logging and Unbound verbosity are **off** by default. For diagnostics:

```bash
/root/dns-troubleshoot.sh on     # enable Unbound + Pi-hole logging; prints how to watch logs
/root/dns-troubleshoot.sh off    # quiet defaults again
/root/dns-troubleshoot.sh status
```

Typical follow-ups while `on`:

```bash
journalctl -u unbound -f
tail -f /var/log/unbound-pihole-debug.log
pihole -t
```

---

## Contribute / rebuild the image

### Packer build

```bash
export DIGITALOCEAN_TOKEN="API_TOKEN"
# or: echo 'do_token = "API_TOKEN"' > variables.auto.pkrvars.hcl

packer init .
packer validate .
packer build .
```

Refresh Marketplace vendor scripts:

```bash
make update-scripts
make validate
```

### Terraform test Droplets

```bash
cd terraform
echo 'do_token = "API_TOKEN"' > terraform.auto.tfvars
echo 'image    = "IMAGE_ID"' >> terraform.auto.tfvars
echo 'ssh_keys = [SSH_ID]'   >> terraform.auto.tfvars

terraform init && terraform validate && terraform apply
terraform show    # Droplet IP
terraform destroy
```

- Use case 1: `IMAGE_ID` = Packer snapshot ID  
- Use case 2: `IMAGE_ID` = `ubuntu-26-04-x64` (script smoke test)

List snapshot / SSH key IDs via the [DigitalOcean API](https://docs.digitalocean.com/reference/api/api-reference/) (`/v2/images?private=true`, `/v2/account/keys`). Terraform **≥ 1.2.0**.

### Script map

See [`scripts/README.md`](scripts/README.md).
