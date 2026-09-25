# Marketplace scripts

| Script | Role |
|--------|------|
| `system-setup.sh` | UFW, fail2ban (sshd), sshd harden drop-in, sysctl, unused-service trim, unattended-upgrades, base README |
| `unbound-setup.sh` | Recursive DNS per Pi-hole Unbound guide (hard-fail if inactive) |
| `wg-setup.sh` | WireGuard packages / keys / MotD / regen helper; seeds `/root/wg-mgmt` |
| `wg-mgmt/*` | Named peer add / remove / list under `/root/wg-mgmt/` |
| `pihole-setup.sh` | Pi-hole install + Unbound-only upstream + admin bind to `10.2.53.1` + host DNS + password |
| `pihole-adlists.sh` | Seed managed URLs into `gravity.db` (`INSERT OR IGNORE` + optional `pihole -g`) |
| `dns-troubleshoot.sh` | Toggle Unbound/Pi-hole diagnostic logging (`/root/dns-troubleshoot.sh`) |
| `ssh-lock.sh` / `ssh-unlock.sh` | First-boot SSH gate |
| `image-cleanup.sh` | Vendored from marketplace-partners `90-cleanup.sh` |
| `image-check.sh` | Vendored from marketplace-partners `99-img-check.sh` |

`remote-check-do.sh` (if present locally) is a one-off API helper and is not part of the Packer bake.

Refresh vendor scripts:

```bash
make update-scripts
```
