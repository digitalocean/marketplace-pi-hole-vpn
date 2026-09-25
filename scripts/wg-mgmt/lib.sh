#!/bin/bash
# Shared helpers for /root/wg-mgmt peer lifecycle tools.
# shellcheck shell=bash

WG_MGMT_DIR="${WG_MGMT_DIR:-/root/wg-mgmt}"
WG_CONF="${WG_CONF:-/etc/wireguard/wg0.conf}"
WG_IFACE="${WG_IFACE:-wg0}"
PEER_DB="${PEER_DB:-${WG_MGMT_DIR}/peers.csv}"
CLIENT_DIR="${CLIENT_DIR:-${WG_MGMT_DIR}/clients}"
WG_SUBNET_PREFIX="${WG_SUBNET_PREFIX:-10.2.53}"
WG_SERVER_HOST="${WG_SERVER_HOST:-1}"

wg_mgmt_ensure_dirs() {
    mkdir -p "${WG_MGMT_DIR}" "${CLIENT_DIR}"
    chmod 700 "${WG_MGMT_DIR}" "${CLIENT_DIR}"
}

wg_mgmt_init_db() {
    wg_mgmt_ensure_dirs
    if [[ ! -f "${PEER_DB}" ]]; then
        printf 'name,public_key,ip\n' > "${PEER_DB}"
        chmod 600 "${PEER_DB}"
    fi
}

wg_mgmt_validate_name() {
    local name="$1"
    local len=${#name}
    if [[ "${len}" -lt 1 || "${len}" -gt 50 ]]; then
        echo "Error: peer name length must be 1-50 characters (got ${len})." >&2
        return 1
    fi
    if [[ ! "${name}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "Error: peer name must match [a-zA-Z0-9_-] only." >&2
        return 1
    fi
}

wg_mgmt_name_exists() {
    local name="$1"
    [[ -f "${PEER_DB}" ]] || return 1
    grep -Eq "^${name}," "${PEER_DB}"
}

wg_mgmt_public_iface() {
    ip -4 route show default 2>/dev/null | awk '{print $5; exit}' || true
}

wg_mgmt_server_endpoint() {
    local iface ipv4 ipv6
    iface="$(wg_mgmt_public_iface)"
    [[ -z "${iface}" ]] && iface="eth0"

    ipv4="$(ip -4 -o addr show dev "${iface}" scope global 2>/dev/null \
        | awk '{print $4}' | cut -d/ -f1 | grep -vE '^10\.|^127\.' | head -n1 || true)"
    if [[ -n "${ipv4}" ]]; then
        printf '%s' "${ipv4}"
        return 0
    fi

    ipv6="$(ip -6 -o addr show dev "${iface}" scope global 2>/dev/null \
        | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
    if [[ -n "${ipv6}" ]]; then
        printf '[%s]' "${ipv6}"
        return 0
    fi

    echo "Error: could not determine a public Endpoint IP" >&2
    return 1
}

wg_mgmt_listen_port() {
    local port
    if [[ -f "${WG_CONF}" ]]; then
        port="$(grep -E '^ListenPort[[:space:]]*=' "${WG_CONF}" | awk '{print $3}' | head -n1 || true)"
    fi
    printf '%s' "${port:-51820}"
}

wg_mgmt_server_pubkey() {
    local pvk
    pvk="$(grep -E '^PrivateKey[[:space:]]*=' "${WG_CONF}" | awk '{print $3}' | head -n1)"
    if [[ -z "${pvk}" ]]; then
        echo "Error: PrivateKey not found in ${WG_CONF}" >&2
        return 1
    fi
    printf '%s' "${pvk}" | wg pubkey
}

wg_mgmt_used_hosts() {
    # Emit used host numbers from AllowedIPs and the peer DB.
    if [[ -f "${WG_CONF}" ]]; then
        grep -Eo "${WG_SUBNET_PREFIX}\.[0-9]+" "${WG_CONF}" \
            | awk -F. '{print $4}' \
            | sort -n -u
    fi
    if [[ -f "${PEER_DB}" ]]; then
        awk -F, -v pfx="${WG_SUBNET_PREFIX}." 'NR>1 {
            ip=$3
            sub(/^[[:space:]]+/,"",ip)
            sub(/[[:space:]]+$/,"",ip)
            if (index(ip, pfx)==1) {
                split(ip, a, ".")
                print a[4]+0
            }
        }' "${PEER_DB}"
    fi
}

wg_mgmt_next_host() {
    local used host
    used="$(wg_mgmt_used_hosts | sort -n -u | tr '\n' ' ')"
    for host in $(seq 2 254); do
        if ! printf ' %s ' "${used}" | grep -Eq " ${host} "; then
            # Skip the server address explicitly
            if [[ "${host}" -eq "${WG_SERVER_HOST}" ]]; then
                continue
            fi
            printf '%s' "${host}"
            return 0
        fi
    done
    echo "Error: no free addresses left in ${WG_SUBNET_PREFIX}.0/24" >&2
    return 1
}

wg_mgmt_reset_db() {
    wg_mgmt_ensure_dirs
    rm -f "${CLIENT_DIR}"/*.conf 2>/dev/null || true
    printf 'name,public_key,ip\n' > "${PEER_DB}"
    chmod 600 "${PEER_DB}"
}

wg_mgmt_db_add() {
    local name="$1" pubkey="$2" ip="$3"
    wg_mgmt_init_db
    # Drop any stale row with the same name
    local tmp
    tmp="$(mktemp)"
    awk -F, -v n="${name}" 'NR==1 || $1 != n { print }' "${PEER_DB}" > "${tmp}"
    mv "${tmp}" "${PEER_DB}"
    printf '%s,%s,%s\n' "${name}" "${pubkey}" "${ip}" >> "${PEER_DB}"
    chmod 600 "${PEER_DB}"
}

wg_mgmt_db_get() {
    local name="$1"
    [[ -f "${PEER_DB}" ]] || return 1
    grep -E "^${name}," "${PEER_DB}" | head -n1
}

wg_mgmt_db_remove() {
    local name="$1"
    local tmp
    tmp="$(mktemp)"
    awk -F, -v n="${name}" 'NR==1 || $1 != n { print }' "${PEER_DB}" > "${tmp}"
    mv "${tmp}" "${PEER_DB}"
    chmod 600 "${PEER_DB}"
}

wg_mgmt_remove_peer_block_by_pubkey() {
    local pubkey="$1"
    local tmp
    tmp="$(mktemp)"
    # Buffer each [Peer] section; drop the one whose PublicKey matches.
    awk -v target="${pubkey}" '
        function flush_peer() {
            if (peer_buf == "") return
            if (!drop_peer) printf "%s", peer_buf
            peer_buf = ""
            drop_peer = 0
            in_peer = 0
        }
        /^\[Peer\]/ {
            flush_peer()
            in_peer = 1
            peer_buf = $0 ORS
            next
        }
        in_peer {
            peer_buf = peer_buf $0 ORS
            if ($0 ~ /^PublicKey[[:space:]]*=/) {
                val = $0
                sub(/^[^=]*=[[:space:]]*/, "", val)
                sub(/[[:space:]]+$/, "", val)
                if (val == target) drop_peer = 1
            }
            next
        }
        { print }
        END { flush_peer() }
    ' "${WG_CONF}" > "${tmp}"
    mv "${tmp}" "${WG_CONF}"
    chmod 600 "${WG_CONF}"
}
