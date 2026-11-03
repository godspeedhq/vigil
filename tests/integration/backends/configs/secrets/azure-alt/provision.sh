#!/usr/bin/env bash
#
# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# provision.sh - the fixtures in Lowkey Vault, for Vigil's azure_keyvault
# store. It keeps them in memory, so scripts/start.sh azure-alt runs this
# after every start. Safe to run again.
#
#   bash configs/secrets/azure-alt/provision.sh
#
# In its default vault, https://127.0.0.1:8443 (it tells vaults apart by
# Host and port), each a new random value:
#   vigil-probe      one version
#   vigil-versioned  two versions: the first fetched by its id, the second
#                    as the latest
#   vigil-rotating   which the tests rotate
#
# With a placeholder bearer token: Lowkey Vault wants one there, and accepts
# any. What the tests need goes in .secrets/azure-alt.env (0600).

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/../../../scripts/common.sh"

sec=$bk_dir/.secrets
vault=https://127.0.0.1:8443
ca=$sec/tls/ca.pem
out=$sec/azure-alt.env

# Secret $1 now holds $2; prints the new version's id.
put() {
    local answer
    answer=$(printf '{"value":"%s"}' "$2" | curl -q -sS -m 10 --cacert "$ca" -X PUT -H 'Authorization: Bearer provisioning' \
        -H 'Content-Type: application/json' --data-binary @- "$vault/secrets/$1?api-version=7.4") || die "cannot write $1"
    printf '%s' "$answer" | sed -n "s|.*\"id\":\"[^\"]*/secrets/$1/\([0-9a-f]*\)\".*|\1|p"
}
rnd() { openssl rand -hex 16; }

# Java takes a few seconds to start.
i=0
until curl -q -s -m 3 --cacert "$ca" -o /dev/null "$vault/ping" || [ "$i" -ge 90 ]; do sleep 1; i=$((i + 1)); done
probe=$(rnd) rotating=$(rnd) v1=$(rnd) v2=$(rnd)
put vigil-probe "$probe" > /dev/null
put vigil-rotating "$rotating" > /dev/null
v1_id=$(put vigil-versioned "$v1")
put vigil-versioned "$v2" > /dev/null
[ -n "$v1_id" ] || die 'no version id in Lowkey Vault'"'"'s answer'

(umask 077 && {
    printf '# Written by configs/secrets/azure-alt/provision.sh at %s; test values for an emulator.\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'ST_URL=%s\nST_VAULT=%s\nST_IMDS=http://127.0.0.1:8081\n' "$vault" "$vault"
    # For the service_principal check: Lowkey Vault has no token endpoint.
    printf 'ST_TENANT=00000000-0000-0000-0000-000000000001\nST_CLIENT_ID=vigil-test\nVIGIL_ST_CLIENT_SECRET=%s\n' "$(rnd)"
    printf 'ST_PROBE=%s\nST_ROTATING=%s\nST_V1=%s\nST_V1_ID=%s\nST_V2=%s\n' "$probe" "$rotating" "$v1" "$v1_id" "$v2"
} > "$out.tmp") && mv -f "$out.tmp" "$out" || die "cannot write $out"
echo "azure-alt provisioned: vigil-probe, vigil-versioned (2 versions), vigil-rotating; see .secrets/azure-alt.env"
