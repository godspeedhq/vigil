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
# rotate.sh - gives the rotating test secret a new value, as an operator
# rotating it would. run-store.sh and run-store.ps1 (through Git Bash) use it.
#
#   printf '%s' "$new" | bash configs/secrets/rotate.sh <target> <target>.env <ca.pem>
#
#   openbao, vault  secret/vigil/rotating, with the token that may write only
#                   that path
#   aws             vigil/rotating, PutSecretValue (the emulator takes any
#                   credentials)
#   azure           vigil-rotating, a new version (the emulator takes any
#                   bearer token)
#   gcp             vigil-rotating, a new version (the emulator needs no
#                   token)
#
# Tokens and the value reach curl on its standard input, as configuration,
# never on its command line.

set -u
[ "$#" -eq 3 ] || { echo 'usage: rotate.sh <target> <target>.env <ca.pem>' >&2; exit 1; }
url=$(sed -n 's/^ST_URL=//p' "$2")
IFS= read -r new || [ -n "$new" ]
# PowerShell pipes a line with CRLF.
new=${new%$'\r'}
# Git Bash's curl uses Windows' Schannel, which wants a revocation answer a
# test CA cannot give. The certificate is still checked against the CA;
# Vigil itself does not check revocation for a ca_file either (spec 6.5.3).
norevoke=()
curl -V 2> /dev/null | grep -qi schannel && norevoke=(--ssl-no-revoke)

case $1 in
    openbao | vault)
        config=$(printf 'header = "X-Vault-Token: %s"\ndata-binary = "{\\"data\\":{\\"value\\":\\"%s\\"}}"\nheader = "Content-Type: application/json"\nurl = "%s/v1/secret/data/vigil/rotating"\n' \
            "$(sed -n 's/^ST_ROTATE_TOKEN=//p' "$2")" "$new" "$url")
        ;;
    aws)
        config=$(printf 'data-binary = "{\\"SecretId\\":\\"vigil/rotating\\",\\"SecretString\\":\\"%s\\"}"\nheader = "Content-Type: application/x-amz-json-1.1"\nheader = "X-Amz-Target: secretsmanager.PutSecretValue"\nurl = "%s/"\n' \
            "$new" "$url")
        ;;
    azure | azure-alt)
        config=$(printf 'request = "PUT"\ndata-binary = "{\\"value\\":\\"%s\\"}"\nheader = "Content-Type: application/json"\nheader = "Authorization: Bearer rotation"\nurl = "%s/secrets/vigil-rotating?api-version=7.4"\n' \
            "$new" "$(sed -n 's/^ST_VAULT=//p' "$2")")
        ;;
    gcp | gcp-alt)
        config=$(printf 'data-binary = "{\\"payload\\":{\\"data\\":\\"%s\\"}}"\nheader = "Content-Type: application/json"\nurl = "%s/v1/projects/%s/secrets/vigil-rotating:addVersion"\n' \
            "$(printf '%s' "$new" | base64 | tr -d '\n')" "$url" "$(sed -n 's/^ST_PROJECT=//p' "$2")")
        ;;
    *) echo "rotate.sh: no rotation for $1" >&2; exit 1 ;;
esac
code=$(printf '%s\n' "$config" | curl -q -sS ${norevoke[@]+"${norevoke[@]}"} -K - --cacert "$3" -o /dev/null -w '%{http_code}')
[ "$code" = 200 ] || { echo "rotate.sh: HTTP $code" >&2; exit 1; }
