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
# provision.sh - the fixtures in Floci's AWS emulator, for Vigil's
# aws_secrets_manager store. The emulator keeps them in memory, so
# scripts/start.sh aws runs this after every start. Safe to run again.
#
#   bash configs/secrets/aws/provision.sh
#
# In region us-east-1, each a new random value:
#   vigil/probe     a string
#   vigil/json      JSON, {"username": "vigil", "password": <random>}, for field
#   vigil/rotating  a string, which the tests rotate
#   vigil/binary    a binary secret, which Vigil does not support
#
# Through the TLS front (https://127.0.0.1:4566, the test CA). The emulator
# accepts any credentials and doesn't check signatures, so these requests
# carry none; Vigil's own requests are signed, as for AWS.
#
# What the tests need goes in .secrets/aws.env (0600): the endpoint, dummy
# access keys, and the values, so run-store can check none of them is ever
# written down.

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/../../../scripts/common.sh"

sec=$bk_dir/.secrets
url=https://127.0.0.1:4566
ca=$sec/tls/ca.pem
out=$sec/aws.env

# A Secrets Manager action $1 with JSON body $2 (on stdin, as it may hold a
# value). Prints the answer; fails on a status that is not 200.
sm() {
    local code
    code=$(printf '%s' "$2" | curl -q -sS --cacert "$ca" -o "$sec/.aws.answer" -w '%{http_code}' \
        -H 'Content-Type: application/x-amz-json-1.1' -H "X-Amz-Target: secretsmanager.$1" --data-binary @- "$url/")
    cat "$sec/.aws.answer"
    rm -f "$sec/.aws.answer"
    [ "$code" = 200 ]
}
# Secret $1 now holds string $2: created, or given a new version.
put() {
    sm CreateSecret "{\"Name\":\"$1\",\"SecretString\":\"$2\"}" > /dev/null 2>&1 ||
        sm PutSecretValue "{\"SecretId\":\"$1\",\"SecretString\":\"$2\"}" > /dev/null || die "cannot write $1"
}
rnd() { openssl rand -hex 16; }

i=0
until curl -q -s --cacert "$ca" -o /dev/null "$url/" || [ "$i" -ge 30 ]; do sleep 1; i=$((i + 1)); done
probe=$(rnd) password=$(rnd) rotating=$(rnd) binary=$(rnd)
put vigil/probe "$probe"
put vigil/json "{\\\"username\\\":\\\"vigil\\\",\\\"password\\\":\\\"$password\\\"}"
put vigil/rotating "$rotating"
b64=$(printf '%s' "$binary" | openssl base64 -A)
sm CreateSecret "{\"Name\":\"vigil/binary\",\"SecretBinary\":\"$b64\"}" > /dev/null 2>&1 ||
    sm PutSecretValue "{\"SecretId\":\"vigil/binary\",\"SecretBinary\":\"$b64\"}" > /dev/null || die 'cannot write vigil/binary'

(umask 077 && {
    printf '# Written by configs/secrets/aws/provision.sh at %s; test values for an emulator.\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'ST_URL=%s\nST_REGION=us-east-1\n' "$url"
    # Dummy keys, in AWS's format: the emulator accepts any.
    printf 'ST_ACCESS_KEY_ID=AKIAVIGILTEST0000001\nVIGIL_ST_SECRET_KEY=%s\n' "$(rnd)$(rnd)"
    printf 'ST_PROBE=%s\nST_PASSWORD=%s\nST_ROTATING=%s\nST_BINARY=%s\n' "$probe" "$password" "$rotating" "$binary"
} > "$out.tmp") && mv -f "$out.tmp" "$out" || die "cannot write $out"
echo "aws provisioned: vigil/probe, vigil/json, vigil/rotating, vigil/binary in us-east-1; see .secrets/aws.env"
