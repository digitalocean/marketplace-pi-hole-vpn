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

public_iface() {
    # Prefer the interface that owns the default IPv4 route
    ip -4 route show default 2>/dev/null | awk '{print $5; exit}' || true
}

server_endpoint_ip() {
    # Prefer public IPv4 (and Floating IP when present on the public iface).
    # Fall back to public IPv6 only when no usable IPv4 exists.
    local iface ipv4 ipv6
    iface="$(public_iface)"
    [[ -z "${iface}" ]] && iface="eth0"

    ipv4="$(ip -4 -o addr show dev "${iface}" scope global 2>/dev/null \
        | awk '{print $4}' | cut -d/ -f1 | grep -vE '^10\.|^127\.' | head -n1 || true)"
    if [[ -n "${ipv4}" ]]; then
        echo -n "${ipv4}"
        return
    fi

    ipv6="$(ip -6 -o addr show dev "${iface}" scope global 2>/dev/null \
        | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
    if [[ -n "${ipv6}" ]]; then
        echo -n "[${ipv6}]"
        return
    fi

    echo "ERROR: could not determine a public Endpoint IP" >&2
    exit 1
}

ensure_ufw_wireguard_nat() {
    local iface
    iface="$(public_iface)"
    [[ -z "${iface}" ]] && iface="eth0"

    # Allow WireGuard traffic if UFW is present
    if command -v ufw >/dev/null 2>&1; then
        ufw allow 51820/udp comment 'WireGuard' >/dev/null 2>&1 || true
        ufw allow in on wg0 >/dev/null 2>&1 || true
        ufw route allow in on wg0 out on "${iface}" >/dev/null 2>&1 || true
        ufw route allow in on "${iface}" out on wg0 >/dev/null 2>&1 || true
    fi

    # NAT + legacy UDP port redirects in UFW before.rules (idempotent block)
    local before_rules="/etc/ufw/before.rules"
    local marker_begin="# BEGIN PIHOLE-VPN-WIREGUARD"
    local marker_end="# END PIHOLE-VPN-WIREGUARD"
    if [[ -f "${before_rules}" ]]; then
        if grep -q "${marker_begin}" "${before_rules}"; then
            # Remove previous block
            sed -i "/${marker_begin}/,/${marker_end}/d" "${before_rules}"
        fi
        # Insert NAT table rules before *filter
        local tmp
        tmp="$(mktemp)"
        awk -v iface="${iface}" -v begin="${marker_begin}" -v end="${marker_end}" '
            BEGIN { inserted=0 }
            /^\*filter/ && !inserted {
                print begin
                print "*nat"
                print ":POSTROUTING ACCEPT [0:0]"
                print ":PREROUTING ACCEPT [0:0]"
                print "-A PREROUTING -i " iface " -p udp -m multiport --dports 123,1194 -j REDIRECT --to-ports 51820"
                print "-A POSTROUTING -s 10.2.53.0/24 -o " iface " -j MASQUERADE"
                print "COMMIT"
                print end
                print ""
                inserted=1
            }
            { print }
        ' "${before_rules}" > "${tmp}"
        mv "${tmp}" "${before_rules}"
    fi

    # Remove any prior IPv6 tunnel NAT block (tunnels are IPv4-only now)
    local before6="/etc/ufw/before6.rules"
    if [[ -f "${before6}" ]] && grep -q "${marker_begin}" "${before6}"; then
        sed -i "/${marker_begin}/,/${marker_end}/d" "${before6}"
    fi

    if command -v ufw >/dev/null 2>&1; then
        ufw reload >/dev/null 2>&1 || true
    fi
}

seed_wg_mgmt_peer() {
    # Register a peer created by wg_conf into /root/wg-mgmt metadata.
    local name="$1" pubkey="$2" ip="$3" client_conf="$4"
    if [[ -f /root/wg-mgmt/lib.sh ]]; then
        # shellcheck source=/dev/null
        source /root/wg-mgmt/lib.sh
        wg_mgmt_db_add "${name}" "${pubkey}" "${ip}"
        wg_mgmt_ensure_dirs
        printf '%s\n' "${client_conf}" > "${CLIENT_DIR}/${name}.conf"
        chmod 600 "${CLIENT_DIR}/${name}.conf"
    else
        mkdir -p /root/wg-mgmt/clients
        if [[ ! -f /root/wg-mgmt/peers.csv ]]; then
            printf 'name,public_key,ip\n' > /root/wg-mgmt/peers.csv
        fi
        printf '%s,%s,%s\n' "${name}" "${pubkey}" "${ip}" >> /root/wg-mgmt/peers.csv
        chmod 600 /root/wg-mgmt/peers.csv
        printf '%s\n' "${client_conf}" > "/root/wg-mgmt/clients/${name}.conf"
        chmod 600 "/root/wg-mgmt/clients/${name}.conf"
    fi
}

reset_wg_mgmt_db() {
    if [[ -f /root/wg-mgmt/lib.sh ]]; then
        # shellcheck source=/dev/null
        source /root/wg-mgmt/lib.sh
        wg_mgmt_reset_db
    else
        mkdir -p /root/wg-mgmt/clients
        rm -f /root/wg-mgmt/clients/*.conf 2>/dev/null || true
        printf 'name,public_key,ip\n' > /root/wg-mgmt/peers.csv
        chmod 600 /root/wg-mgmt/peers.csv
    fi
}

wg_conf() {
    local nconfs="${1:-1}"
    local print_conf="${2:-true}"
    local server_ip pvk spbk output i cpbk psk addrs full_vpn peer_name listen_port
    server_ip="$(server_endpoint_ip)"
    listen_port=51820
    pvk="$(wg genkey)"
    spbk="$(echo -n "${pvk}" | wg pubkey)"
    local wg0_conf
    wg0_conf="[Interface]
Address = 10.2.53.1/24
ListenPort = ${listen_port}
PrivateKey = ${pvk}
"
    reset_wg_mgmt_db
    output=""
    for i in $(seq "${nconfs}")
    do
        pvk="$(wg genkey)"
        cpbk="$(echo -n "${pvk}" | wg pubkey)"
        psk="$(wg genpsk)"
        addrs="10.2.53.$((i+1))/32"
        peer_name="client${i}"
        full_vpn="\
[Interface]
Address = ${addrs}
DNS = 10.2.53.1
PrivateKey = ${pvk}

[Peer]
Endpoint = ${server_ip}:${listen_port}
PersistentKeepalive = 25
PublicKey = ${spbk}
PresharedKey = ${psk}
AllowedIPs = 0.0.0.0/0, ::/0"

        output="${output}\
From client ${i}'s WireGuard app (${peer_name}), scan the QR code below:

$(echo "${full_vpn}" | qrencode -t utf8)
$(if ${print_conf}; then echo "${full_vpn}"; fi)
"
        wg0_conf="${wg0_conf}
# peer_name=${peer_name}
[Peer]
PublicKey = ${cpbk}
PresharedKey = ${psk}
AllowedIPs = ${addrs}
"
        seed_wg_mgmt_peer "${peer_name}" "${cpbk}" "10.2.53.$((i+1))" "${full_vpn}"
    done
    mkdir -p /etc/wireguard
    chmod 700 /etc/wireguard
    echo -n "${wg0_conf}" > /etc/wireguard/wg0.conf
    chmod 600 /etc/wireguard/wg0.conf
    systemctl enable wg-quick@wg0.service
    systemctl daemon-reload
    systemctl start wg-quick@wg0
    systemctl restart wg-quick@wg0
    echo -n "${output}"
}

install_packages() {
    echo "STEP: Install WireGuard & dependencies ..."
    apt-get -qqy update
    apt-get -qqy -o Dpkg::Options::="--force-confdef" \
                 -o Dpkg::Options::="--force-confold" install \
                 qrencode \
                 wireguard \
                 wireguard-tools
    apt-get -qqy autoremove
    apt-get -qqy clean
    echo "WireGuard & dependency installation complete."
}

update_readme() {
    touch /root/README
    perl -C -Mutf8 -i -p0e \
        's/^\n+█▀+\n█ WIREGUARD.*WIREGUARD █\n▄+█\n//sme' \
        /root/README
    cat >> /root/README <<'EOF'


█▀▀▀▀▀▀▀▀▀▀
█ WIREGUARD

WireGuard is the VPN software used. Consider donating at:

                 wireguard.com/donations
                 ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄


Client Endpoint addresses prefer the Droplet's public IPv4 address
(including a Floating / Reserved IP when assigned to the public
interface). IPv6 is used only when no public IPv4 address is found.
Edit the Endpoint in the client config if you need the other family.

WireGuard tunnel addresses are IPv4-only (10.2.53.0/24). Client
configs use Full VPN (AllowedIPs 0.0.0.0/0, ::/0) so all traffic
routes over the tunnel. Client requests show the Pi-hole VPN
server IP; some sites may show more captchas.


Peer management (add / remove without rotating everyone):

    /root/wg-mgmt/add-wg-peer.sh <name>      # add one device
    /root/wg-mgmt/remove-wg-peer.sh <name>   # remove one device
    /root/wg-mgmt/list-wg-peers.sh           # list managed peers

Configs are saved under /root/wg-mgmt/clients/ and tracked in
/root/wg-mgmt/peers.csv. Initial MotD peers are named client1,
client2, ...

Need to regenerate ALL keys for any reason?

    /root/regen-vpn-keys.sh <NUM_CLIENTS>

e.g.
    /root/regen-vpn-keys.sh 2

WARNING: regen-vpn-keys.sh invalidates every existing client.
         Prefer add-wg-peer.sh / remove-wg-peer.sh for day-to-day
         device changes.


But my network blocks port 51820 ... are there other options?

This server will also route the following UDP ports to WireGuard:
• 1194 (OpenVPN): Try this first
• 123  (NTP)    : If 1194 doesn't work, try 123

Recommended Cloud Firewall: TCP 22, UDP 51820 (and optionally
UDP 1194 / 123 if you use the redirects above).

WIREGUARD █
▄▄▄▄▄▄▄▄▄▄█
EOF
}

nconfs="${1:-1}"
if [[ -n ${nconfs//[0-9]/} || ${nconfs} -lt 1 ]]; then
    echo "Cannot create '${nconfs}' configs; specify integer >= 1."
    exit 1
fi

if [[ "$(basename "${0}")" == 'regen-vpn-keys.sh' ]]; then
    install_packages
    ensure_ufw_wireguard_nat
    wg_conf "${nconfs}"
    rm -f /etc/update-motd.d/99-getting-started
    exit 0
fi

install_packages

if is_build; then
    echo "Build mode: packages installed; key generation deferred to first boot."
    exit 0
fi

echo "STEP: Configure WireGuard NAT / UFW ..."
ensure_ufw_wireguard_nat
echo "Firewall NAT configuration complete."

echo "STEP: Configure WireGuard ..."
mkdir -p /etc/update-motd.d
echo -n "#!/bin/sh
cat <<EOF
=========================================================================
$(wg_conf "${nconfs}" false)

                                    ❓
             Can't scan? Multiple clients? Other questions?
                  Run the command below for more info:

                               cat README

             Add a device:  /root/wg-mgmt/add-wg-peer.sh <name>
             List peers:    /root/wg-mgmt/list-wg-peers.sh
=========================================================================
To delete this message of the day:
    rm -rf \$(readlink -f \${0})
EOF
" > /etc/update-motd.d/99-getting-started
chmod 700 /etc/update-motd.d/99-getting-started
echo "WireGuard and MotD configuration complete."

update_readme
echo "README update complete."
