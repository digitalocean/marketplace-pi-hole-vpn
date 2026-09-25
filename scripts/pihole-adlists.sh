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

# Seed Pi-hole v6 adlists into gravity.db (idempotent INSERT OR IGNORE).
# Usage:
#   pihole-adlists.sh              # insert lists; run gravity update
#   pihole-adlists.sh --no-gravity # insert lists only
#   pihole-adlists.sh /path/to/blocklists.txt [--no-gravity]

set -euo pipefail

DB="${PIHOLE_GRAVITY_DB:-/etc/pihole/gravity.db}"
DEFAULT_LISTS="/usr/local/share/pihole-vpn/blocklists.txt"
COMMENT="Managed by marketplace-pi-hole-vpn"
RUN_GRAVITY=1
LISTS=""

for arg in "$@"; do
    case "${arg}" in
        --no-gravity)
            RUN_GRAVITY=0
            ;;
        -h|--help)
            echo "Usage: $0 [blocklists.txt] [--no-gravity]"
            exit 0
            ;;
        *)
            if [[ -n "${LISTS}" ]]; then
                echo "ERROR: unexpected argument: ${arg}" >&2
                exit 1
            fi
            LISTS="${arg}"
            ;;
    esac
done

LISTS="${LISTS:-${DEFAULT_LISTS}}"

if [[ ! -f "${LISTS}" ]]; then
    echo "ERROR: blocklist file not found: ${LISTS}" >&2
    exit 1
fi

if [[ ! -f "${DB}" ]]; then
    echo "ERROR: gravity database not found: ${DB}" >&2
    exit 1
fi

if ! command -v pihole-FTL >/dev/null 2>&1; then
    echo "ERROR: pihole-FTL not found" >&2
    exit 1
fi

echo "STEP: Seed managed adlists from ${LISTS} ..."
count=0
# shellcheck disable=SC2013
while IFS= read -r url || [[ -n "${url}" ]]; do
    # Trim whitespace
    url="$(echo "${url}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ -z "${url}" || "${url}" =~ ^# ]] && continue
    # Escape single quotes for SQL literal
    sql_url="${url//\'/\'\'}"
    pihole-FTL sqlite3 "${DB}" \
        "INSERT OR IGNORE INTO adlist (address, enabled, type, comment)
         VALUES ('${sql_url}', 1, 0, '${COMMENT}');"
    count=$((count + 1))
done < <(grep -Ev '^\s*(#|$)' "${LISTS}" || true)

echo "Processed ${count} adlist URL(s) (INSERT OR IGNORE)."

if [[ "${RUN_GRAVITY}" -eq 1 ]]; then
    echo "STEP: Rebuild gravity (pihole -g) ..."
    pihole -g
    echo "Gravity update complete."
else
    echo "Skipping gravity rebuild (--no-gravity)."
fi
