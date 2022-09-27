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

echo "STEP 1: Configure firewall ..."
for chain in INPUT FORWARD OUTPUT
do
    for cmd in iptables ip6tables
    do
        "${cmd}" -P "${chain}" ACCEPT
    done
done
for chain in PREROUTING INPUT OUTPUT POSTROUTING
do
    for cmd in iptables ip6tables
    do
        "${cmd}" -P "${chain}" ACCEPT -t nat
    done
done
for cmd in iptables ip6tables
do
    "${cmd}" -F
    "${cmd}" -F -t nat
    "${cmd}" -A INPUT -i eth0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    "${cmd}" -A INPUT -i eth0 -p tcp -m tcp ! --dport 22 -j DROP
    "${cmd}" -A INPUT -i eth0 -p udp -m udp ! --dport 51820 -j DROP
    "${cmd}" -A INPUT -i eth0 -p tcp -m tcp --dport 22 -m recent --update --seconds 60 --hitcount 6 --name SSH --rsource -j DROP
    "${cmd}" -A INPUT -i eth0 -p tcp -m tcp --dport 22 -m recent --set --name SSH --rsource -j ACCEPT
    "${cmd}" -A INPUT -p icmp -m limit --limit 60/minute --limit-burst 120 -j ACCEPT
    "${cmd}" -A INPUT -i lo -j ACCEPT
    "${cmd}" -P INPUT DROP
    "${cmd}" -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    "${cmd}" -P FORWARD DROP
done
mkdir -p /etc/iptables
iptables -Z -t nat
iptables -Z
iptables-save > /etc/iptables/rules.v4
ip6tables -Z -t nat
ip6tables -Z
ip6tables-save > /etc/iptables/rules.v6
echo "Firewall configuration complete."


echo "STEP 2: Update system ..."
export DEBIAN_FRONTEND=noninteractive
apt-get -qqy update
apt-get -qqy -o Dpkg::Options::="--force-confdef" \
             -o Dpkg::Options::="--force-confold" full-upgrade
apt-get -qqy -o Dpkg::Options::="--force-confdef" \
             -o Dpkg::Options::="--force-confold" install \
                iptables-persistent
apt-get -qqy autoremove
apt-get -qqy clean
echo "System update complete."


echo "STEP 3: Installing base README ..."
cat <<EOF > /root/README


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
EOF
echo "Base README installation complete."

echo "System setup complete."
