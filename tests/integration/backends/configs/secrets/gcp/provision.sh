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
# provision.sh - the fixtures in Floci's GCP emulator, for Vigil's
# gcp_secret_manager store. The emulator keeps them in memory, so
# scripts/start.sh gcp runs this after every start. Safe to run again.
#
#   bash configs/secrets/gcp/provision.sh [gcp-alt]
#
# With gcp-alt, the same fixtures go to Blackwell's emulator
# (https://127.0.0.1:4598) and its values to .secrets/gcp-alt.env. The keys
# are shared: their token_uri is always Floci's /token, as Blackwell has none.
#
# In project vigil-test, each a new random value:
#   vigil-probe      one version
#   vigil-versioned  two more versions: the first fetched by its number, the
#                    second as latest
#   vigil-rotating   which the tests rotate
#
# Service account keys, in Google's JSON format, each with a new RSA key, so
# Vigil signs its JWT exactly as it would for Google; the emulator accepts
# any. Made once and kept, in .secrets/ (git-ignored):
#   gcp-key.json        token_uri https://127.0.0.1:4588/token, the emulator's
#   gcp-key-http.json   the same key, token_uri plain http: Vigil refuses it
#   gcp-key-other.json  another key: Google would refuse it; the emulator
#                       doesn't check
#
# Through the TLS front (https://127.0.0.1:4588, the test CA). What the
# tests need goes in .secrets/gcp.env (0600).

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/../../../scripts/common.sh"

sec=$bk_dir/.secrets
url=https://127.0.0.1:4588
token_uri=$url/token
out=$sec/gcp.env
if [ "${1-}" = gcp-alt ]; then
    url=https://127.0.0.1:4598
    out=$sec/gcp-alt.env
fi
project=vigil-test
ca=$sec/tls/ca.pem

# A REST call: method $1, path $2, JSON body $3 on stdin. The answer goes
# in $sec/.gcp.answer.
call() {
    printf '%s' "$3" | curl -q -sS --cacert "$ca" -o "$sec/.gcp.answer" -w '%{http_code}' -X "$1" \
        -H 'Content-Type: application/json' --data-binary @- "$url/v1/projects/$project$2"
}
# Secret $1 gets a new version holding $2; prints the version's number. Run
# again, the emulator adds versions, so numbers are read from its answer.
add() {
    local code
    call POST "/secrets?secretId=$1" '{"replication":{"automatic":{}}}' > /dev/null
    code=$(call POST "/secrets/$1:addVersion" "{\"payload\":{\"data\":\"$(printf '%s' "$2" | openssl base64 -A)\"}}")
    [ "$code" = 200 ] || die "cannot add a version to $1 (HTTP $code)"
    sed -n 's|.*"name":"[^"]*/versions/\([0-9]*\)".*|\1|p' "$sec/.gcp.answer"
    rm -f "$sec/.gcp.answer"
}
# A service account key file $1, with token_uri $2 and the RSA key in $3.
key_file() {
    local pem
    pem=$(awk '{ printf "%s\\n", $0 }' "$3")
    (umask 077 && printf '{"type":"service_account","project_id":"%s","private_key_id":"vigil-test","private_key":"%s","client_email":"vigil@%s.iam.gserviceaccount.com","client_id":"1","token_uri":"%s"}\n' \
        "$project" "$pem" "$project" "$2" > "$1")
}
rnd() { openssl rand -hex 16; }

i=0
until curl -q -s --cacert "$ca" -o /dev/null "$url/" || [ "$i" -ge 30 ]; do sleep 1; i=$((i + 1)); done

if [ ! -f "$sec/gcp-key.json" ] || [ ! -f "$sec/gcp-key-other.json" ]; then
    work=$(mktemp -d) || exit 1
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$work/a.pem" 2> /dev/null &&
        openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$work/b.pem" 2> /dev/null || die 'openssl cannot make an RSA key'
    key_file "$sec/gcp-key.json" "$token_uri" "$work/a.pem"
    key_file "$sec/gcp-key-http.json" "http://127.0.0.1:4588/token" "$work/a.pem"
    key_file "$sec/gcp-key-other.json" "$token_uri" "$work/b.pem"
    rm -rf "$work"
fi

probe=$(rnd) v1=$(rnd) v2=$(rnd) rotating=$(rnd)
add vigil-probe "$probe" > /dev/null
v1_n=$(add vigil-versioned "$v1")
add vigil-versioned "$v2" > /dev/null
add vigil-rotating "$rotating" > /dev/null
[ -n "$v1_n" ] || die 'no version number in the emulator'"'"'s answer'

(umask 077 && {
    printf '# Written by configs/secrets/gcp/provision.sh at %s; test values for an emulator.\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'ST_URL=%s\nST_PROJECT=%s\n' "$url" "$project"
    printf 'ST_PROBE=%s\nST_V1=%s\nST_V1_N=%s\nST_V2=%s\nST_ROTATING=%s\n' "$probe" "$v1" "$v1_n" "$v2" "$rotating"
} > "$out.tmp") && mv -f "$out.tmp" "$out" || die "cannot write $out"
echo "${1:-gcp} provisioned: vigil-probe, vigil-versioned (2 versions), vigil-rotating in $project; see ${out#"$sec"/}"
