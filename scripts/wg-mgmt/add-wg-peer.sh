#!/bin/bash
# Add a named WireGuard peer without regenerating existing keys.
# Usage: /root/wg-mgmt/add-wg-peer.sh <peer_name>
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

if [[ ! -f "${WG_CONF}" ]]; then
    echo "Error: ${WG_CONF} not found. Run WireGuard setup / regen first." >&2
    exit 1
fi

if wg_mgmt_name_exists "${peer_name}"; then
    echo "Error: peer name '${peer_name}' is already in use." >&2
    exit 1
fi

if ! wg show "${WG_IFACE}" >/dev/null 2>&1; then
    echo "Error: ${WG_IFACE} is not up; start wg-quick@${WG_IFACE} first." >&2
    exit 1
fi

next_host="$(wg_mgmt_next_host)"
client_ip="${WG_SUBNET_PREFIX}.${next_host}"
server_ip="$(wg_mgmt_server_endpoint)"
wg_port="$(wg_mgmt_listen_port)"
server_pubkey="$(wg_mgmt_server_pubkey)"

client_privkey="$(wg genkey)"
client_pubkey="$(printf '%s' "${client_privkey}" | wg pubkey)"
psk="$(wg genpsk)"

client_conf="[Interface]
Address = ${client_ip}/32
DNS = ${WG_SUBNET_PREFIX}.${WG_SERVER_HOST}
PrivateKey = ${client_privkey}

[Peer]
Endpoint = ${server_ip}:${wg_port}
PersistentKeepalive = 25
PublicKey = ${server_pubkey}
PresharedKey = ${psk}
AllowedIPs = 0.0.0.0/0, ::/0"

{
    printf '\n# peer_name=%s\n' "${peer_name}"
    printf '[Peer]\n'
    printf 'PublicKey = %s\n' "${client_pubkey}"
    printf 'PresharedKey = %s\n' "${psk}"
    printf 'AllowedIPs = %s/32\n' "${client_ip}"
} >> "${WG_CONF}"
chmod 600 "${WG_CONF}"

if ! wg set "${WG_IFACE}" \
    peer "${client_pubkey}" \
    preshared-key <(printf '%s' "${psk}") \
    allowed-ips "${client_ip}/32"; then
    echo "Error: failed to add peer to live ${WG_IFACE}; rolling back conf append is manual." >&2
    exit 1
fi

client_file="${CLIENT_DIR}/${peer_name}.conf"
printf '%s\n' "${client_conf}" > "${client_file}"
chmod 600 "${client_file}"

wg_mgmt_db_add "${peer_name}" "${client_pubkey}" "${client_ip}"

echo
echo "=========== FULL VPN (${peer_name}) ==========="
echo "${client_conf}" | qrencode -t utf8
echo "${client_conf}"
echo
echo "Saved: ${client_file}"
echo "Name : ${peer_name}"
echo "IP   : ${client_ip}/32"
echo "DB   : ${PEER_DB}"
