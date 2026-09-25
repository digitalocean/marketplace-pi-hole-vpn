#!/bin/bash

# Copyright 2022 The marketplace-pi-hole-vpn Authors All rights reserved.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#     http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

is_build() {
    [[ "${MARKETPLACE_BUILD:-}" == "1" ]]
}

# Refresh indexes immediately before install/upgrade to avoid mirror 404 races.
apt_update() {
    apt-get -qqy update
}

apt_install() {
    local attempt
    for attempt in 1 2 3; do
        apt_update
        if apt-get -qqy -o Dpkg::Options::="--force-confdef" \
                        -o Dpkg::Options::="--force-confold" \
                        --fix-missing install "$@"; then
            return 0
        fi
        echo "apt install failed (attempt ${attempt}); retrying after refresh..." >&2
        sleep $((attempt * 5))
    done
    echo "apt install failed after retries: $*" >&2
    return 1
}

apt_upgrade() {
    local attempt
    for attempt in 1 2 3; do
        apt_update
        if apt-get -qqy -o Dpkg::Options::="--force-confdef" \
                        -o Dpkg::Options::="--force-confold" \
                        --fix-missing upgrade; then
            return 0
        fi
        echo "apt upgrade failed (attempt ${attempt}); retrying after refresh..." >&2
        sleep $((attempt * 5))
    done
    echo "apt upgrade failed after retries" >&2
    return 1
}

configure_sysctl() {
    echo "STEP: Configure sysctl ..."
    cat > /etc/sysctl.d/99-pihole-vpn.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.core.rmem_max=1048576
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.default.accept_source_route=0
net.ipv4.conf.all.log_martians=1
net.ipv4.conf.default.log_martians=1
net.ipv4.tcp_syncookies=1
kernel.kptr_restrict=2
kernel.dmesg_restrict=1
EOF
    sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-pihole-vpn.conf
    echo "Sysctl configuration complete."
}

disable_unused_services() {
    echo "STEP: Disable unused services (if present) ..."
    local svc
    for svc in avahi-daemon cups bluetooth ModemManager; do
        if systemctl list-unit-files "${svc}.service" 2>/dev/null | grep -q "${svc}.service"; then
            systemctl disable --now "${svc}.service" >/dev/null 2>&1 || true
            echo "  disabled ${svc}.service"
        fi
    done
    echo "Unused service trim complete."
}

configure_sshd_hardening() {
    echo "STEP: Harden sshd (drop-in) ..."
    mkdir -p /etc/ssh/sshd_config.d
    cat > /etc/ssh/sshd_config.d/99-pihole-vpn-hardened.conf <<'EOF'
# Marketplace Pi-hole VPN hardening (complements UFW + fail2ban).
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 30
MaxAuthTries 3
EOF
    if command -v sshd >/dev/null 2>&1; then
        if sshd -t 2>/dev/null; then
            systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null \
                || systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
            echo "sshd hardening applied."
        else
            echo "ERROR: sshd -t failed after writing hardened drop-in; removing it." >&2
            rm -f /etc/ssh/sshd_config.d/99-pihole-vpn-hardened.conf
            return 1
        fi
    else
        echo "sshd not present yet; drop-in written for next start."
    fi
}

install_base_packages() {
    echo "STEP: Install base packages (ufw, fail2ban, unattended-upgrades, curl) ..."
    apt_install ufw fail2ban unattended-upgrades apt-listchanges openssl ca-certificates curl
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
    dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true
    echo "Base packages installed."
}

configure_ufw() {
    echo "STEP: Configure UFW ..."

    # On an already-running Droplet, do not wipe rules (would drop WireGuard NAT).
    # Full reset only during image bake or when UFW is not yet active.
    local ufw_active=0
    if ufw status 2>/dev/null | grep -q 'Status: active'; then
        ufw_active=1
    fi

    if is_build || [[ "${ufw_active}" -eq 0 ]]; then
        ufw --force reset >/dev/null 2>&1 || true
        ufw default deny incoming
        ufw default allow outgoing
        ufw default deny forward
    fi

    ufw limit 22/tcp comment 'SSH rate-limited' >/dev/null 2>&1 || true
    ufw allow 51820/udp comment 'WireGuard' >/dev/null 2>&1 || true
    # Do not open 53/80/443 publicly — Pi-hole is VPN-only

    # WireGuard needs forwarding; route rules are added when wg0 is created
    sed -i 's/^#*DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
    if grep -q '^IPV6=' /etc/default/ufw; then
        sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
    else
        echo 'IPV6=yes' >> /etc/default/ufw
    fi

    ufw --force enable
    ufw status verbose || true
    echo "UFW configuration complete."
}

configure_fail2ban() {
    echo "STEP: Configure fail2ban (sshd via UFW) ..."
    mkdir -p /etc/fail2ban/jail.d
    # Drop-in keeps distro jail.conf intact; bans integrate with UFW.
    cat > /etc/fail2ban/jail.d/sshd-pihole-vpn.local <<'EOF'
[DEFAULT]
banaction = ufw
banaction_allports = ufw
backend = systemd

[sshd]
enabled = true
port = ssh
filter = sshd
maxretry = 5
findtime = 10m
bantime = 1h
EOF
    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban
    # Show sshd jail status when fail2ban-client is ready
    sleep 1
    fail2ban-client status sshd 2>/dev/null || fail2ban-client status 2>/dev/null || true
    echo "fail2ban configuration complete."
}

security_upgrade() {
    echo "STEP: Apply security upgrades ..."
    apt_upgrade
    apt-get -qqy autoremove
    apt-get -qqy clean
    echo "Security upgrades complete."
}

install_base_readme() {
    echo "STEP: Installing base README ..."
    cat > /root/README <<'EOF'


          IT'S DANGEROUS TO GO ALONE! TAKE THIS.

                            ⚔️


                 !Hello new Pi-hole user!
                 ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄


Pi-hole is a network-wide ad blocker, typically installed in one's
home network, often, but not always, on a Raspberry Pi. Home lab
operators might configure a VPN into their home network so they
can leverage Pi-hole and other services while they are away.

However, Pi-hole can also be used by running it on a virtual
machine in the cloud. This is particularly useful for folks who
don't operate a home lab, or simply don't want to have a VPN into
their home network.

Operating a Pi-hole server is relatively simple, but there are
some things you should know. See each section below for relevant
information about configuring and managing your server.

Recommended DigitalOcean Cloud Firewall inbound rules:
  • TCP 22   (SSH)
  • UDP 51820 (WireGuard)
  • Optionally UDP 1194 and UDP 123 (redirected to WireGuard)

Pi-hole DNS and the admin UI are reachable only over the VPN
(not on the public interface).

SSH is rate-limited by UFW and protected by fail2ban (sshd jail;
bans applied through UFW). Password authentication is disabled;
use SSH keys. Check fail2ban with:

    fail2ban-client status sshd
EOF
    echo "Base README installation complete."
}

echo "System setup starting (build=$(is_build && echo yes || echo no)) ..."
configure_sysctl
disable_unused_services
install_base_packages
configure_ufw
configure_fail2ban
configure_sshd_hardening

if is_build; then
    security_upgrade
    install_base_readme
else
    # First boot: keep README if present; refresh UFW/sysctl/fail2ban
    if [[ ! -f /root/README ]]; then
        install_base_readme
    fi
fi

echo "System setup complete."
