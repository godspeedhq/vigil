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
# provision.sh - the fixtures in Floci's Azure emulator, for Vigil's
# azure_keyvault store. The emulator keeps them in memory, so
# scripts/start.sh azure runs this after every start. Safe to run again.
#
#   bash configs/secrets/azure/provision.sh
#
# In the vault vigiltest (https://127.0.0.1:4577/vigiltest-keyvault), each a
# new random value:
#   vigil-probe      one version
#   vigil-versioned  two versions: the first is fetched by its id, the second
#                    as the latest
#   vigil-rotating   which the tests rotate
#
# Through the TLS front, with a placeholder bearer token: the emulator wants
# one there, and accepts any.
#
# What the tests need goes in .secrets/azure.env (0600): the vault, the
# emulated tenant, a client id and dummy secret, the managed-identity
# endpoint, the first version's id, and the values, so run-store can check
# none of them is ever written down.

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/../../../scripts/common.sh"

sec=$bk_dir/.secrets
url=https://127.0.0.1:4577
vault=$url/vigiltest-keyvault
ca=$sec/tls/ca.pem
out=$sec/azure.env

# Secret $1 now holds $2; prints the new version's id.
put() {
    local answer
    answer=$(printf '{"value":"%s"}' "$2" | curl -q -sS --cacert "$ca" -X PUT -H 'Authorization: Bearer provisioning' \
        -H 'Content-Type: application/json' --data-binary @- "$vault/secrets/$1?api-version=7.4") || die "cannot write $1"
    printf '%s' "$answer" | sed -n "s|.*\"id\":\"[^\"]*/secrets/$1/\([0-9a-f]*\)\".*|\1|p"
}
rnd() { openssl rand -hex 16; }

i=0
until curl -q -s --cacert "$ca" -o /dev/null "$url/" || [ "$i" -ge 30 ]; do sleep 1; i=$((i + 1)); done
probe=$(rnd) rotating=$(rnd) v1=$(rnd) v2=$(rnd)
put vigil-probe "$probe" > /dev/null
put vigil-rotating "$rotating" > /dev/null
v1_id=$(put vigil-versioned "$v1")
put vigil-versioned "$v2" > /dev/null
[ -n "$v1_id" ] || die 'no version id in the emulator'"'"'s answer'

(umask 077 && {
    printf '# Written by configs/secrets/azure/provision.sh at %s; test values for an emulator.\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'ST_URL=%s\nST_VAULT=%s\nST_IMDS=http://127.0.0.1:4578\n' "$url" "$vault"
    printf 'ST_TENANT=00000000-0000-0000-0000-000000000001\nST_CLIENT_ID=vigil-test\nVIGIL_ST_CLIENT_SECRET=%s\n' "$(rnd)"
    printf 'ST_PROBE=%s\nST_ROTATING=%s\nST_V1=%s\nST_V1_ID=%s\nST_V2=%s\n' "$probe" "$rotating" "$v1" "$v1_id" "$v2"
} > "$out.tmp") && mv -f "$out.tmp" "$out" || die "cannot write $out"
echo "azure provisioned: vigil-probe, vigil-versioned (2 versions), vigil-rotating in vigiltest; see .secrets/azure.env"
