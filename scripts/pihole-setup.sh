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

# Pin the installer download for reproducibility; update deliberately.
# Source: https://install.pi-hole.net (redirects to pi-hole/pi-hole)
PIHOLE_INSTALL_URL="${PIHOLE_INSTALL_URL:-https://install.pi-hole.net}"

is_build() {
    [[ "${MARKETPLACE_BUILD:-}" == "1" ]]
}

seed_pihole_config() {
    local iface="${1:-wg0}"
    local bind_admin="${2:-}"
    mkdir -p /etc/pihole

    # Legacy setupVars.conf still accepted for unattended installs / upgrades
    cat > /etc/pihole/setupVars.conf <<EOF
PIHOLE_INTERFACE=${iface}
QUERY_LOGGING=false
INSTALL_WEB_SERVER=true
INSTALL_WEB_INTERFACE=true
LIGHTTPD_ENABLED=false
CACHE_SIZE=10000
DNS_FQDN_REQUIRED=true
DNS_BOGUS_PRIV=true
DNSMASQ_LISTENING=local
BLOCKING_ENABLED=true
DNSSEC=true
REV_SERVER=false
PIHOLE_DNS_1=127.0.0.1#5335
PIHOLE_DNS_2=127.0.0.1#5335
IPV4_ADDRESS=10.2.53.1/24
IPV6_ADDRESS=
EOF

    # Pi-hole v6 primary config (unattended requires a pre-seeded file)
    if [[ -n "${bind_admin}" ]]; then
        cat > /etc/pihole/pihole.toml <<EOF
[dns]
  upstreams = [ "127.0.0.1#5335" ]
  dnssec = true
  interface = "${iface}"
  listeningMode = "LOCAL"
  queryLogging = false

[webserver]
  port = "${bind_admin}:80o"
EOF
    else
        cat > /etc/pihole/pihole.toml <<EOF
[dns]
  upstreams = [ "127.0.0.1#5335" ]
  dnssec = true
  interface = "${iface}"
  listeningMode = "LOCAL"
  queryLogging = false
EOF
    fi
}

verify_pihole_upstream() {
    local upstreams
    if ! command -v pihole-FTL >/dev/null 2>&1; then
        echo "ERROR: pihole-FTL not found after configure" >&2
        exit 1
    fi
    upstreams="$(pihole-FTL --config dns.upstreams 2>/dev/null || true)"
    if ! printf '%s' "${upstreams}" | grep -Fq '127.0.0.1#5335'; then
        echo "ERROR: Pi-hole upstream is not Unbound-only (got: ${upstreams})" >&2
        exit 1
    fi
    if printf '%s' "${upstreams}" | grep -Eqi 'cloudflare|1\.1\.1\.1|8\.8\.8\.8|9\.9\.9\.9|google'; then
        echo "ERROR: unexpected public resolver in Pi-hole upstreams: ${upstreams}" >&2
        exit 1
    fi
}

bind_admin_to_wg() {
    local bind_ip="${1:-10.2.53.1}"
    echo "STEP: Bind Pi-hole admin UI to ${bind_ip}:80 only ..."
    if ! command -v pihole-FTL >/dev/null 2>&1; then
        echo "ERROR: pihole-FTL not found" >&2
        exit 1
    fi
    pihole-FTL --config webserver.port "${bind_ip}:80o"
    local actual
    actual="$(pihole-FTL --config webserver.port 2>/dev/null || true)"
    if ! printf '%s' "${actual}" | grep -Fq "${bind_ip}"; then
        echo "ERROR: webserver.port did not bind to ${bind_ip} (got: ${actual})" >&2
        exit 1
    fi
    echo "Admin UI bound to ${actual}"
}

configure_host_resolver() {
    echo "STEP: Point host resolver at local Pi-hole (systemd-resolved) ..."
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/99-pihole-vpn.conf <<'EOF'
[Resolve]
DNS=127.0.0.1
Domains=~.
EOF
    # Keep distro symlink to systemd-resolved; do not freeze /etc/resolv.conf
    if [[ -L /etc/resolv.conf ]] || [[ ! -e /etc/resolv.conf ]]; then
        ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || true
    fi
    systemctl enable systemd-resolved >/dev/null 2>&1 || true
    systemctl restart systemd-resolved >/dev/null 2>&1 || true
    echo "Host resolver configuration complete."
}

install_pihole() {
    local iface="${1:-wg0}"
    if command -v pihole >/dev/null 2>&1; then
        echo "Pi-hole already installed; refreshing upstream configuration."
        return 0
    fi

    echo "STEP: Install Pi-hole (unattended) ..."
    seed_pihole_config "${iface}"
    local installer="/tmp/install-pihole.sh"
    curl -fsSL "${PIHOLE_INSTALL_URL}" -o "${installer}"
    # Basic sanity: installer must be a non-trivial shell script
    if [[ ! -s "${installer}" ]] || ! head -n1 "${installer}" | grep -qE '^#!.*(bash|sh)'; then
        echo "ERROR: Pi-hole installer download failed validation" >&2
        exit 1
    fi
    chmod 700 "${installer}"
    "${installer}" --unattended
    rm -f "${installer}"
    echo "Pi-hole installation complete."
}

configure_upstream_and_interface() {
    local iface="${1:-wg0}"
    local bind_admin="${2:-}"
    echo "STEP: Ensure Pi-hole uses only local Unbound (interface=${iface}, LOCAL) ..."
    seed_pihole_config "${iface}" "${bind_admin}"
    # Prefer CLI when available (v6)
    if command -v pihole-FTL >/dev/null 2>&1; then
        pihole-FTL --config dns.upstreams '[ "127.0.0.1#5335" ]'
        pihole-FTL --config dns.interface "${iface}"
        pihole-FTL --config dns.listeningMode "LOCAL"
        pihole-FTL --config dns.dnssec true
        pihole-FTL --config dns.queryLogging false
        if [[ -n "${bind_admin}" ]]; then
            bind_admin_to_wg "${bind_admin}"
        fi
    fi
    systemctl restart pihole-FTL 2>/dev/null || service pihole-FTL restart 2>/dev/null || true
    if ! systemctl is-active --quiet pihole-FTL 2>/dev/null \
        && ! systemctl is-active --quiet pihole-FTL.service 2>/dev/null; then
        # Some installs use a different unit name; require the binary respond.
        if ! pihole-FTL --config dns.upstreams >/dev/null 2>&1; then
            echo "ERROR: pihole-FTL is not healthy after configure" >&2
            exit 1
        fi
    fi
    verify_pihole_upstream
    echo "Upstream configuration complete."
}

set_admin_password() {
    local password
    if command -v openssl >/dev/null 2>&1; then
        password="$(openssl rand -base64 18 | tr -d '/+=' | head -c 20)"
    else
        password="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)"
    fi
    if command -v pihole >/dev/null 2>&1; then
        # v6 CLI
        if pihole setpassword "${password}" >/dev/null 2>&1; then
            :
        elif pihole -a -p "${password}" >/dev/null 2>&1; then
            :
        else
            echo "${password}" | pihole setpassword >/dev/null 2>&1 || \
                echo "${password}" | pihole -a -p >/dev/null 2>&1 || true
        fi
    fi
    echo -n "${password}" > /root/.pihole_admin_password
    chmod 600 /root/.pihole_admin_password
    echo "${password}"
}

update_readme() {
    local password="${1:-}"
    touch /root/README
    perl -C -Mutf8 -i -p0e \
        's/^\n+█▀+\n█ PIHOLE.*PIHOLE █\n▄+█\n//sme' \
        /root/README
    cat >> /root/README <<EOF


█▀▀▀▀▀▀▀
█ PIHOLE

Pi-hole is the ad block software used. Consider donating at:

                 pi-hole.net/donate
                 ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄

DNS path: VPN client → Pi-hole → local Unbound (127.0.0.1#5335)
→ DNS root / TLD / authoritative servers. No public upstream
resolvers are configured.

The Droplet host resolver also uses local Pi-hole (127.0.0.1)
via systemd-resolved (Domains=~.), not DigitalOcean DHCP DNS.

To access the Pi-hole dashboard, connect to the VPN and visit:

    http://pi.hole/admin
    or http://10.2.53.1/admin

The admin UI listens only on 10.2.53.1 (WireGuard), not on the
public interface.

Query logging is off by default. To enable diagnostic logging:

    /root/dns-troubleshoot.sh on

Default blocklists are seeded into gravity.db at image build
(comment: "Managed by marketplace-pi-hole-vpn"). Refresh with:

    pihole -g

EOF
    if [[ -n "${password}" ]]; then
        cat >> /root/README <<EOF
Initial admin password (also in /root/.pihole_admin_password):

    ${password}

To set / reset the admin password later:

    pihole setpassword

EOF
    else
        cat >> /root/README <<'EOF'
To set / reset the admin password:

    pihole setpassword

EOF
    fi
    cat >> /root/README <<'EOF'
It is recommended to upgrade at least once a month:

    apt update
    apt upgrade
    reboot # if necessary
    pihole -up

PIHOLE █
▄▄▄▄▄▄▄█
EOF
}

append_password_to_motd() {
    local password="$1"
    cat > /etc/update-motd.d/98-pihole-password <<EOF
#!/bin/sh
echo "Pi-hole admin password: ${password}"
echo "(Also saved in /root/.pihole_admin_password and /root/README)"
EOF
    chmod 700 /etc/update-motd.d/98-pihole-password
}

seed_managed_adlists() {
    # Args forwarded to pihole-adlists.sh (e.g. --no-gravity)
    local seeder="/usr/local/sbin/pihole-adlists.sh"
    if [[ ! -x "${seeder}" ]]; then
        echo "ERROR: ${seeder} not found; Packer must install pihole-adlists.sh before this step" >&2
        exit 1
    fi
    "${seeder}" "$@"
}

# Build: install against the public NIC (wg0 does not exist yet).
# First boot: rebind to wg0 after WireGuard starts.
if is_build; then
    build_iface="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"
    [[ -z "${build_iface}" ]] && build_iface="eth0"
    install_pihole "${build_iface}"
    configure_upstream_and_interface "${build_iface}"
    configure_host_resolver
    seed_managed_adlists
    update_readme ""
    echo "Build mode: Pi-hole installed; admin password deferred to first boot."
    exit 0
fi

install_pihole "wg0"

# First boot: wait briefly for wg0 if WireGuard just started
for _ in $(seq 1 30); do
    if ip link show wg0 >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

configure_upstream_and_interface "wg0" "10.2.53.1"
configure_host_resolver
# Ensure managed URL rows exist; gravity already built at image bake time
seed_managed_adlists --no-gravity
ADMIN_PASSWORD="$(set_admin_password)"
update_readme "${ADMIN_PASSWORD}"
append_password_to_motd "${ADMIN_PASSWORD}"

# Confirm FTL is forwarding to Unbound when possible
dig +time=3 +tries=1 en.wikipedia.org @127.0.0.1 >/dev/null 2>&1 || true

echo "Pi-hole first-boot configuration complete."
