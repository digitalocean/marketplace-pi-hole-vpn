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

# Toggle Unbound verbosity + Pi-hole query logging for diagnostics.
# Avoids full pihole-FTL restarts (those reload gravity and can take ~60s on
# 1 GB Droplets). pihole-FTL --config applies queryLogging in-process.

set -euo pipefail

UNBOUND_CONF="/etc/unbound/unbound.conf.d/pi-hole.conf"
UNBOUND_DEBUG_LOG="/var/log/unbound-pihole-debug.log"

usage() {
    cat <<'EOF'
Usage: /root/dns-troubleshoot.sh on|off|status

  on     Enable Unbound + Pi-hole diagnostic logging
  off    Restore quiet defaults (logging off)
  status Show current logging settings

Query logging and Unbound verbosity are off by default.
Remember to run "off" when finished to save disk and CPU.
EOF
}

unbound_verbosity() {
    if [[ -f "${UNBOUND_CONF}" ]]; then
        awk '/^[[:space:]]*verbosity:/{print $2; exit}' "${UNBOUND_CONF}" || echo "?"
    else
        echo "missing"
    fi
}

pihole_query_logging() {
    if command -v pihole-FTL >/dev/null 2>&1; then
        # Suppress the value echo on stdout noise for callers that only need status text
        pihole-FTL --config dns.queryLogging 2>/dev/null | tr -d '\r'
    else
        echo "missing"
    fi
}

print_status() {
    echo "Unbound verbosity: $(unbound_verbosity) (quiet default is 0)"
    echo "Pi-hole queryLogging: $(pihole_query_logging) (quiet default is false)"
}

reload_unbound() {
    # Prefer in-process reload (fast); fall back to systemd reload/restart.
    if command -v unbound-control >/dev/null 2>&1 && unbound-control status >/dev/null 2>&1; then
        unbound-control reload >/dev/null
        return 0
    fi
    if systemctl reload unbound >/dev/null 2>&1; then
        return 0
    fi
    systemctl restart unbound
}

set_unbound_logging() {
    local verbosity="$1"
    local enable_logfile="$2"

    if [[ ! -f "${UNBOUND_CONF}" ]]; then
        echo "ERROR: ${UNBOUND_CONF} not found" >&2
        exit 1
    fi

    # Single rewrite pass: set verbosity and managed logfile block
    awk -v verbosity="${verbosity}" -v enable_logfile="${enable_logfile}" -v logf="${UNBOUND_DEBUG_LOG}" '
        BEGIN { in_dbg=0; wrote_dbg=0 }
        /^[[:space:]]*# BEGIN PIHOLE-VPN-DEBUG$/ { in_dbg=1; next }
        /^[[:space:]]*# END PIHOLE-VPN-DEBUG$/ { in_dbg=0; next }
        in_dbg { next }
        /^[[:space:]]*verbosity:/ {
            print "    verbosity: " verbosity
            if (enable_logfile == "1" && !wrote_dbg) {
                print "    # BEGIN PIHOLE-VPN-DEBUG"
                print "    logfile: \"" logf "\""
                print "    # END PIHOLE-VPN-DEBUG"
                wrote_dbg=1
            }
            next
        }
        { print }
    ' "${UNBOUND_CONF}" > "${UNBOUND_CONF}.tmp"
    mv "${UNBOUND_CONF}.tmp" "${UNBOUND_CONF}"

    if [[ "${enable_logfile}" == "1" ]]; then
        touch "${UNBOUND_DEBUG_LOG}"
        chown unbound:unbound "${UNBOUND_DEBUG_LOG}" 2>/dev/null || true
        chmod 640 "${UNBOUND_DEBUG_LOG}"
    fi

    unbound-checkconf >/dev/null
    reload_unbound
}

set_pihole_query_logging() {
    local value="$1"
    if ! command -v pihole-FTL >/dev/null 2>&1; then
        echo "ERROR: pihole-FTL not found" >&2
        exit 1
    fi

    # Applies immediately; do NOT systemctl restart pihole-FTL (reloads gravity, ~60s).
    pihole-FTL --config dns.queryLogging "${value}" >/dev/null

    if [[ -f /etc/pihole/setupVars.conf ]] && grep -q '^QUERY_LOGGING=' /etc/pihole/setupVars.conf; then
        sed -i "s/^QUERY_LOGGING=.*/QUERY_LOGGING=${value}/" /etc/pihole/setupVars.conf
    fi
}

print_log_directions() {
    cat <<EOF

How to watch logs while troubleshooting
---------------------------------------
Unbound (recursive DNS behind Pi-hole):
  journalctl -u unbound -f
  tail -f ${UNBOUND_DEBUG_LOG}

Pi-hole (FTL / query log):
  pihole -t
  tail -f /var/log/pihole/pihole.log
  Or open the Query Log in the admin UI over the VPN:
    http://pi.hole/admin   or   http://10.2.53.1/admin

When finished:
  /root/dns-troubleshoot.sh off
EOF
}

already_desired() {
    local want_on="$1" # 1=on, 0=off
    local v q
    v="$(unbound_verbosity)"
    q="$(pihole_query_logging)"
    if [[ "${want_on}" -eq 1 ]]; then
        [[ "${v}" == "3" && "${q}" == "true" ]]
    else
        [[ "${v}" == "0" && "${q}" == "false" ]]
    fi
}

cmd="${1:-}"
case "${cmd}" in
    on)
        if already_desired 1; then
            echo "Diagnostic logging already enabled."
            print_status
            print_log_directions
            exit 0
        fi
        echo "Enabling diagnostic logging ..."
        set_unbound_logging 3 1
        set_pihole_query_logging true
        print_status
        print_log_directions
        ;;
    off)
        if already_desired 0; then
            echo "Diagnostic logging already disabled (quiet defaults)."
            print_status
            exit 0
        fi
        echo "Disabling diagnostic logging (quiet defaults) ..."
        set_unbound_logging 0 0
        set_pihole_query_logging false
        print_status
        echo "Logging restored to quiet defaults."
        ;;
    status|"")
        if [[ -z "${cmd}" ]]; then
            usage
            echo
        fi
        print_status
        ;;
    *)
        usage >&2
        exit 1
        ;;
esac
