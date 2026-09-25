#!/bin/bash
# List managed WireGuard peers (CSV + live interface status).
# Usage: /root/wg-mgmt/list-wg-peers.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

wg_mgmt_init_db

echo "Managed peers (${PEER_DB}):"
if [[ ! -s "${PEER_DB}" ]] || [[ "$(wc -l < "${PEER_DB}")" -le 1 ]]; then
    echo "  (none)"
else
    column -t -s, "${PEER_DB}" 2>/dev/null || cat "${PEER_DB}"
fi

echo
if wg show "${WG_IFACE}" >/dev/null 2>&1; then
    echo "Live ${WG_IFACE} peers:"
    wg show "${WG_IFACE}" peers || true
else
    echo "Live ${WG_IFACE}: not up"
fi
