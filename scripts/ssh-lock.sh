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

echo "Lock SSH during system setup ..."
cat >> /etc/ssh/sshd_config <<EOM
Match User root
    ForceCommand printf "Please wait while we perform initial setup....\n\nNB: If you attempt to SSH in too frequently, the firewall will temporarily lock you out.\nWe recommend putting a sleep 15 after your ssh command, e.g.\n\n    ssh root@\$(ip -4 a s scope global eth0 | grep 'inet ' | grep -v 'inet 10\.' | awk -F'[ \t/]+' '{printf \$3}') || sleep 15\n\n"; false
EOM
echo "SSH locked."
