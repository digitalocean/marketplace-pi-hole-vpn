#!/bin/bash
# Remove a named WireGuard peer without touching other clients.
# Usage: /root/wg-mgmt/remove-wg-peer.sh <peer_name>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <peer_name>"
    echo "peer_name: 1-50 characters, [a-zA-Z0-9_-]"
    exit 1
fi

peer_name="$1"
wg_mgmt_validate_name "${peer_name}"
wg_mgmt_init_db

record="$(wg_mgmt_db_get "${peer_name}" || true)"
if [[ -z "${record}" ]]; then
    echo "Error: peer '${peer_name}' not found in ${PEER_DB}." >&2
    echo "List peers with: ${WG_MGMT_DIR}/list-wg-peers.sh" >&2
    exit 1
fi

peer_pubkey="$(printf '%s' "${record}" | awk -F, '{print $2}')"
peer_ip="$(printf '%s' "${record}" | awk -F, '{print $3}')"

if wg show "${WG_IFACE}" >/dev/null 2>&1; then
    if ! wg set "${WG_IFACE}" peer "${peer_pubkey}" remove; then
        echo "Error: failed to remove peer from live ${WG_IFACE}." >&2
        exit 1
    fi
    echo "Removed from live ${WG_IFACE}."
else
    echo "Warning: ${WG_IFACE} is not up; skipped live remove."
fi

if [[ -f "${WG_CONF}" ]]; then
    wg_mgmt_remove_peer_block_by_pubkey "${peer_pubkey}"
    # Also drop a preceding # peer_name= line if present
    sed -i "/^# peer_name=${peer_name}\$/d" "${WG_CONF}"
    chmod 600 "${WG_CONF}"
    echo "Removed peer block from ${WG_CONF}."
fi

wg_mgmt_db_remove "${peer_name}"
rm -f "${CLIENT_DIR}/${peer_name}.conf"

echo
echo "Peer removed."
echo " Name : ${peer_name}"
echo " PubKey: ${peer_pubkey}"
echo " IP   : ${peer_ip}"
echo
"${SCRIPT_DIR}/list-wg-peers.sh" || true
