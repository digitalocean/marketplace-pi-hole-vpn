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

wg_conf () {
    nconfs="${1:-1}"
    print_conf="${2:-true}"
    IP4="$(ip -4 a s scope global eth0 | grep 'inet ' | grep -v 'inet 10\.' | awk -F'[ \t/]+' '{print $3}')"
    IP6="$(ip -6 a s scope global eth0 | grep 'inet6 ' | awk -F'[ \t/]+' '{print $3}')"
    postup="\
iptables  -w -A PREROUTING -d $IP4 -p udp -m multiport --dports 123,1194 -j REDIRECT --to-ports 51820 -t nat; \
ip6tables -w -A PREROUTING -d $IP6 -p udp -m multiport --dports 123,1194 -j REDIRECT --to-ports 51820 -t nat; \
iptables  -w -A INPUT -i eth0 -p udp -m udp --dport 51820 -j ACCEPT; \
ip6tables -w -A INPUT -i eth0 -p udp -m udp --dport 51820 -j ACCEPT; \
iptables  -w -A INPUT -i wg0 -j ACCEPT; \
ip6tables -w -A INPUT -i wg0 -j ACCEPT; \
iptables  -w -A FORWARD -i wg0 -j ACCEPT; \
ip6tables -w -A FORWARD -i wg0 -j ACCEPT; \
iptables  -w -A POSTROUTING -o eth0 -j MASQUERADE -t nat; \
ip6tables -w -A POSTROUTING -o eth0 -j MASQUERADE -t nat"
    postdown="\
iptables  -w -D PREROUTING -d $IP4 -p udp -m multiport --dports 123,1194 -j REDIRECT --to-ports 51820 -t nat; \
ip6tables -w -D PREROUTING -d $IP6 -p udp -m multiport --dports 123,1194 -j REDIRECT --to-ports 51820 -t nat; \
iptables  -w -D INPUT -i eth0 -p udp -m udp --dport 51820 -j ACCEPT; \
ip6tables -w -D INPUT -i eth0 -p udp -m udp --dport 51820 -j ACCEPT; \
iptables  -w -D INPUT -i wg0 -j ACCEPT; \
ip6tables -w -D INPUT -i wg0 -j ACCEPT; \
iptables  -w -D FORWARD -i wg0 -j ACCEPT; \
ip6tables -w -D FORWARD -i wg0 -j ACCEPT; \
iptables  -w -D POSTROUTING -o eth0 -j MASQUERADE -t nat; \
ip6tables -w -D POSTROUTING -o eth0 -j MASQUERADE -t nat"
    pvk="$(wg genkey)"
    spbk="$(echo -n "${pvk}" | wg pubkey)"
    wg0_conf="[Interface]
Address = 10.2.53.1/24, fc10:253::1/32
ListenPort = 51820
PrivateKey = ${pvk}
PostUp = ${postup}
PostDown = ${postdown}
"
    output=""
    for i in $(seq "${nconfs}")
    do
        pvk="$(wg genkey)"
        cpbk="$(echo -n "${pvk}" | wg pubkey)"
        psk="$(wg genpsk)"
        addrs="10.2.53.$((i+1))/32, fc10:253::$((i+1))/128"
        conf="\
[Interface]
Address = ${addrs}
DNS = 10.2.53.1
PrivateKey = ${pvk}

[Peer]
Endpoint = ${IP4}:51820
PersistentKeepalive = 25
PublicKey = ${spbk}
PresharedKey = ${psk}"
        dns_only="\
${conf}
AllowedIPs = 10.2.53.1/32, fc10:253::1/128"
        full_vpn="\
${conf}
AllowedIPs = 0.0.0.0/0, ::/0"

        output="${output}\
From client ${i}'s WireGuard app, add a connection for one or both of the
available VPN types by scanning the appropriate code(s) below:

                            ⇒ DNS Only VPN ⇐
$(echo "${dns_only}" | qrencode -t utf8)
$(if ${print_conf}; then echo "${dns_only}"; fi)

                              ⇒ Full VPN ⇐
$(echo "${full_vpn}" | qrencode -t utf8)
$(if ${print_conf}; then echo "${full_vpn}"; fi)
"
        wg0_conf="${wg0_conf}
[Peer]
PublicKey = ${cpbk}
PresharedKey = ${psk}
AllowedIPs = ${addrs}
"
done
    mkdir -p /etc/wireguard
    chmod 700 /etc/wireguard
    echo -n "$wg0_conf" > /etc/wireguard/wg0.conf
    chmod 600 /etc/wireguard/wg0.conf
    sudo systemctl enable wg-quick@wg0.service
    sudo systemctl daemon-reload
    sudo systemctl start wg-quick@wg0
    sudo systemctl restart wg-quick@wg0
    echo -n "${output}"
}

nconfs="${1:-1}"
if [[ -n ${nconfs//[0-9]/} || ${nconfs} -lt 1 ]]
then
    echo "Cannot create '${nconfs}' configs; specify integer >= 1."
    exit 1
fi
if [[ "$(basename "${0}")" == 'regen-vpn-keys.sh' ]]
then
    wg_conf "${nconfs}"
    # MotD, created when called as install script, contains old QR code
    rm -f /etc/update-motd.d/99-getting-started
    exit 0
fi


echo "STEP 1: Install WireGuard & dependencies ..."
export DEBIAN_FRONTEND=noninteractive
apt-get -qqy update
apt-get -qqy -o Dpkg::Options::="--force-confdef" \
             -o Dpkg::Options::="--force-confold" install \
             qrencode \
             wireguard \
             wireguard-tools
apt-get -qqy autoremove
apt-get -qqy clean
echo "WireGuard & dependency installation complete."


echo "STEP 2: Enable forwarding ..."
for file in /etc/sysctl.conf /etc/sysctl.d/99-sysctl.conf
do
    sed -e 's/^#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' \
        -e 's/^#net.ipv6.conf.all.forwarding=1/net.ipv6.conf.all.forwarding=1/' \
        -i "${file}"
done
sysctl -p
echo "Forwarding enabled."

echo "STEP 3: Configure WireGuard ..."
echo -n "#!/bin/sh
cat <<EOF
=========================================================================
$(wg_conf "${nconfs}" false)

                                    ❓
             Can't scan? Multiple clients? Other questions?
                  Run the command below for more info:

                               cat README
=========================================================================
To delete this message of the day:
    rm -rf \$(readlink -f \${0})
EOF
" > /etc/update-motd.d/99-getting-started
chmod 700 /etc/update-motd.d/99-getting-started
echo "Wireguard and MotD configuration complete."


echo "STEP 4: Update README ..."
touch /root/README
perl -C -Mutf8 -i -p0e \
    's/^\n+█▀+\n█ WIREGUARD.*WIREGUARD █\n▄+█\n//sme' \
    /root/README
cat <<EOF >> /root/README


█▀▀▀▀▀▀▀▀▀▀
█ WIREGUARD

WireGuard is the VPN software used. Consider donating at:

                 wireguard.com/donations
                 ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄


Have multiple clients / users?
Can't scan QR codes on one or more clients?
Need to regenerate keys for any reason?

Run the following script to generate ALL new keys/configs:

    /root/regen-vpn-keys.sh <NUM_CLIENTS>

e.g.
    ./regen-vpn-keys.sh 2

WARNING: All peers (i.e. clients) will need to scan the new QR
         codes or manually enter the new config info.


Why is there more than one QR code per client? Options ...

⇒ DNS Only VPN

  Only the client's DNS traffic is routed over the VPN. This is
  sufficient for Pi-Hole to do its job.

  Client requests will show Carrier / ISP assigned IP. Therefore,
  most sites / services will work normally.

  Benefits: Faster than full VPN, generally works as expected
  Use When: On a trusted network but still need Ad blocking

⇒ Full VPN

  All traffic is routed over the VPN.

  Client requests will show Pi-Hole VPN server IP. Therefore,
  some sites / services might not work or have more captchas.

  Benefits: Increased privacy / security
  Use When: On untrusted networks


But my network blocks port 51820 ... are there other options?

This server will also route the following UDP ports to WireGuard:
• 1194 (OpenVPN): Try this first
• 123  (NTP)    : If 1194 doesn't work, try 123

WIREGUARD █
▄▄▄▄▄▄▄▄▄▄█
EOF
echo "README update complete."
