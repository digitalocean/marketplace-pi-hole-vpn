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


echo "STEP 1: Install Unbound  ..."
mkdir -p /etc/unbound/unbound.conf.d
cat << EOF > /etc/unbound/unbound.conf.d/pi-hole.conf
server:
    verbosity: 0
    interface: 127.0.0.1
    port: 5335
    do-ip4: yes
    do-udp: yes
    do-tcp: yes
    do-ip6: yes
    access-control: 127.0.0.0/8 allow
    access-control: 0.0.0.0/0 deny
    access-control: ::1 allow
    access-control: ::0/0 deny
    prefer-ip6: no
    hide-identity: yes
    hide-version: yes
    harden-glue: yes
    harden-dnssec-stripped: yes
    use-caps-for-id: no
    edns-buffer-size: 1232
    prefetch: yes
    num-threads: 1
    so-rcvbuf: 1m
    private-address: 192.168.0.0/16
    private-address: 169.254.0.0/16
    private-address: 172.16.0.0/12
    private-address: 10.0.0.0/8
    private-address: fc00::/7
    private-address: fe80::/10
EOF
mkdir -p /etc/dnsmasq.d
echo 'edns-packet-max=1232' > /etc/dnsmasq.d/99-edns.conf
export DEBIAN_FRONTEND=noninteractive
apt-get -qqy update
apt-get -qqy -o Dpkg::Options::="--force-confdef" \
             -o Dpkg::Options::="--force-confold" install \
             unbound
apt-get -qqy autoremove
apt-get -qqy clean
echo "Unbound installation complete."


echo "STEP 2: Update README ..."
touch /root/README
perl -C -Mutf8 -i -p0e \
    's/^\n+█▀+\n█ UNBOUND.*UNBOUND █\n▄+█\n//sme' \
    /root/README
cat <<EOF >> /root/README


█▀▀▀▀▀▀▀▀
█ UNBOUND

Unbound is the recursive DNS software used. Consider donating at:

                 nlnetlabs.nl/funding/
                 ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄

You shouldn't need to do anything for Unbound. The configuration
is based on the Pi-Hole guide found here:

    https://docs.pi-hole.net/guides/dns/unbound/


UNBOUND █
▄▄▄▄▄▄▄▄█
EOF
echo "README update complete."
