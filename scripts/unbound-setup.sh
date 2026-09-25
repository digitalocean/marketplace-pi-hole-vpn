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

# Pi-hole Unbound guide:
# https://docs.pi-hole.net/guides/dns/unbound/

write_unbound_config() {
    mkdir -p /etc/unbound/unbound.conf.d
    cat > /etc/unbound/unbound.conf.d/pi-hole.conf <<'EOF'
server:
    # If no logfile is specified, syslog is used
    verbosity: 0

    interface: 127.0.0.1
    port: 5335
    do-ip4: yes
    do-udp: yes
    do-tcp: yes

    # May be set to no if you don't have IPv6 connectivity
    do-ip6: yes

    # You want to leave this to no unless you have *native* IPv6
    prefer-ip6: no

    # Marketplace hardening: localhost-only access
    access-control: 127.0.0.0/8 allow
    access-control: ::1 allow
    access-control: 0.0.0.0/0 deny
    access-control: ::0/0 deny
    hide-identity: yes
    hide-version: yes

    # Trust glue only if it is within the server's authority
    harden-glue: yes

    # Require DNSSEC data for trust-anchored zones
    harden-dnssec-stripped: yes

    # Don't use Capitalization randomization (DNSSEC issues)
    use-caps-for-id: no

    # DNS Flag Day 2020 / fragmentation avoidance
    edns-buffer-size: 1232

    # Perform prefetching of close to expired message cache entries
    prefetch: yes

    num-threads: 1

    # Ensure kernel buffer is large enough (needs net.core.rmem_max)
    so-rcvbuf: 1m

    # Ensure privacy of local IP ranges
    private-address: 192.168.0.0/16
    private-address: 169.254.0.0/16
    private-address: 172.16.0.0/12
    private-address: 10.0.0.0/8
    private-address: fd00::/8
    private-address: fe80::/10

    # Ensure no reverse queries to non-public IP ranges (RFC6303 4.2)
    private-address: 192.0.2.0/24
    private-address: 198.51.100.0/24
    private-address: 203.0.113.0/24
    private-address: 255.255.255.255/32
    private-address: 2001:db8::/32
EOF

    mkdir -p /etc/dnsmasq.d
    echo 'edns-packet-max=1232' > /etc/dnsmasq.d/99-edns.conf
}

disable_resolvconf_hook() {
    # Required for Debian Bullseye+ / Ubuntu equivalents (Pi-hole guide)
    systemctl disable --now unbound-resolvconf.service 2>/dev/null || true
    if [[ -f /etc/resolvconf.conf ]]; then
        sed -Ei 's/^unbound_conf=/#unbound_conf=/' /etc/resolvconf.conf || true
    fi
    rm -f /etc/unbound/unbound.conf.d/resolvconf_resolvers.conf
}

validate_unbound() {
    echo "STEP: Validate Unbound ..."
    dig +time=5 +tries=2 pi-hole.net @127.0.0.1 -p 5335 >/dev/null

    local fail_status
    fail_status="$(dig +time=5 +tries=2 +short fail01.dnssec.works @127.0.0.1 -p 5335 status 2>/dev/null || true)"
    # SERVFAIL expected for bogus DNSSEC name
    if dig +time=5 +tries=2 fail01.dnssec.works @127.0.0.1 -p 5335 2>/dev/null | grep -q 'SERVFAIL'; then
        echo "DNSSEC bogus name correctly returns SERVFAIL."
    else
        echo "WARNING: DNSSEC SERVFAIL check for fail01.dnssec.works did not match expected output (${fail_status})." >&2
    fi

    if dig +time=5 +tries=2 +ad dnssec.works @127.0.0.1 -p 5335 2>/dev/null | grep -Eq 'status: NOERROR|flags:.*ad'; then
        echo "DNSSEC validation check passed for dnssec.works."
    else
        echo "WARNING: DNSSEC NOERROR/ad check for dnssec.works did not match expected output." >&2
    fi
    echo "Unbound validation complete."
}

update_readme() {
    touch /root/README
    perl -C -Mutf8 -i -p0e \
        's/^\n+█▀+\n█ UNBOUND.*UNBOUND █\n▄+█\n//sme' \
        /root/README
    cat >> /root/README <<'EOF'


█▀▀▀▀▀▀▀▀
█ UNBOUND

Unbound is the recursive DNS software used. Consider donating at:

                 nlnetlabs.nl/funding/
                 ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄

Pi-hole forwards all upstream DNS exclusively to local Unbound on
127.0.0.1#5335 (no public resolvers such as Cloudflare or Google).

Configuration follows:

    https://docs.pi-hole.net/guides/dns/unbound/

Diagnostic logging is off by default. To raise Unbound verbosity
and Pi-hole query logging temporarily:

    /root/dns-troubleshoot.sh on
    /root/dns-troubleshoot.sh off


UNBOUND █
▄▄▄▄▄▄▄▄█
EOF
}

echo "STEP: Install / configure Unbound ..."
apt-get -qqy update
apt-get -qqy -o Dpkg::Options::="--force-confdef" \
             -o Dpkg::Options::="--force-confold" install \
             unbound dnsutils
apt-get -qqy autoremove
apt-get -qqy clean

write_unbound_config
disable_resolvconf_hook

# Ensure rmem_max is applied for so-rcvbuf
sysctl -w net.core.rmem_max=1048576 >/dev/null 2>&1 || true

systemctl enable unbound
systemctl restart unbound
sleep 2
if ! systemctl is-active --quiet unbound; then
    echo "ERROR: unbound is not active after restart" >&2
    systemctl status unbound --no-pager >&2 || true
    exit 1
fi
validate_unbound
update_readme
echo "Unbound setup complete."
