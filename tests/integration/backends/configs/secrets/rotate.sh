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
# rotate.sh - gives secret/vigil/rotating a new value, as an operator
# rotating a secret would, with the token that may write only that path.
# run-store.sh and run-store.ps1 (through Git Bash) use it.
#
#   printf '%s' "$new" | bash configs/secrets/rotate.sh <target>.env <ca.pem>
#
# The token and the value reach curl on its standard input, as configuration,
# never on its command line.

set -u
[ "$#" -eq 2 ] || { echo 'usage: rotate.sh <target>.env <ca.pem>' >&2; exit 1; }
url=$(sed -n 's/^ST_URL=//p' "$1")
token=$(sed -n 's/^ST_ROTATE_TOKEN=//p' "$1")
IFS= read -r new || [ -n "$new" ]
# PowerShell pipes a line with CRLF.
new=${new%$'\r'}
# Git Bash's curl uses Windows' Schannel, which wants a revocation answer a
# test CA cannot give. The certificate is still checked against the CA;
# Vigil itself does not check revocation for a ca_file either (spec 6.5.3).
norevoke=()
curl -V 2> /dev/null | grep -qi schannel && norevoke=(--ssl-no-revoke)
code=$(printf 'header = "X-Vault-Token: %s"\ndata-binary = "{\\"data\\":{\\"value\\":\\"%s\\"}}"\n' "$token" "$new" |
    curl -q -sS ${norevoke[@]+"${norevoke[@]}"} -K - --cacert "$2" -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' "$url/v1/secret/data/vigil/rotating")
[ "$code" = 200 ] || { echo "rotate.sh: HTTP $code" >&2; exit 1; }
