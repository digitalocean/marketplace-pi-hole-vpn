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

echo "STEP 1: Install Pi-hole ..."
mkdir -p /etc/pihole
cat <<EOF > /etc/pihole/setupVars.conf
PIHOLE_INTERFACE=wg0
QUERY_LOGGING=true
INSTALL_WEB_SERVER=true
INSTALL_WEB_INTERFACE=true
LIGHTTPD_ENABLED=true
CACHE_SIZE=10000
DNS_FQDN_REQUIRED=true
DNS_BOGUS_PRIV=true
DNSMASQ_LISTENING=single
BLOCKING_ENABLED=true
DNSSEC=true
REV_SERVER=false
PIHOLE_DNS_1=127.0.0.1#5335
PIHOLE_DNS_2=127.0.0.1#5335
IPV4_ADDRESS=10.2.53.1/24
IPV6_ADDRESS=fc10:253::1/32
EOF
curl -sSL https://install.pi-hole.net -o /tmp/install-pihole.sh
chmod 700 /tmp/install-pihole.sh
/tmp/install-pihole.sh --unattended
echo "Pi-hole installation complete."


echo "STEP 2: Update README ..."
touch /root/README
perl -C -Mutf8 -i -p0e \
    's/^\n+█▀+\n█ PIHOLE.*PIHOLE █\n▄+█\n//sme' \
    /root/README
cat <<EOF >> /root/README


█▀▀▀▀▀▀▀
█ PIHOLE

Pi-hole is the ad block software used. Consider donating at:

                 pi-hole.net/donate
                 ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄

To access the Pi-hole dashboard, connect to the VPN and visit:

    http://pi.hole/admin

To set / reset the admin password run:

    pihole -a -p

It is recommended to upgrade at least once a month:

    apt update
    apt upgrade
    reboot # if necessary
    pi-hole -up

PIHOLE █
▄▄▄▄▄▄▄█
EOF
echo "README update complete."
