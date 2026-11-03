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
# tls.sh - the test CA, and a certificate from it for localhost and
# 127.0.0.1, for the secret stores in compose.secrets.yaml. Made once and
# kept, so a store restarted later still has the certificate Vigil trusts.
# scripts/start.sh runs it before starting a store.
#
#   bash configs/secrets/tls.sh
#
# In .secrets/, which is git-ignored:
#   ca-key.pem     the CA's key, never mounted into a container
#   tls/ca.pem     the CA: Vigil's ca_file, and on other test hosts too
#   tls/server.pem, tls/server-key.pem   the stores' certificate and key
#
# The server key is readable by all (0644): the containers run as uid 100,
# not as you. It is a test key for 127.0.0.1, worth nothing anywhere else.
# Delete .secrets/ to start again with a new CA (then scripts/reset.sh the
# stores too, whose unseal keys are kept there).

set -u
here=$(cd "$(dirname "$0")" && pwd)
dir=$(cd "$here/../.." && pwd)/.secrets
tls=$dir/tls

[ -f "$tls/ca.pem" ] && [ -f "$tls/server.pem" ] && [ -f "$tls/server-key.pem" ] && exit 0
command -v openssl > /dev/null 2>&1 || { echo 'tls.sh needs openssl' >&2; exit 1; }
mkdir -p "$tls" && chmod 700 "$dir" || exit 1

work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
printf 'basicConstraints = critical, CA:FALSE\nkeyUsage = critical, digitalSignature, keyEncipherment\nextendedKeyUsage = serverAuth\nsubjectAltName = DNS:localhost, IP:127.0.0.1\n' > "$work/ext"

(umask 077 && openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj '/CN=Vigil test CA' \
    -addext 'basicConstraints = critical, CA:TRUE' -addext 'keyUsage = critical, keyCertSign, cRLSign' \
    -keyout "$dir/ca-key.pem" -out "$tls/ca.pem" 2> /dev/null) &&
    openssl req -newkey rsa:2048 -nodes -subj '/CN=localhost' -keyout "$tls/server-key.pem" -out "$work/server.csr" 2> /dev/null &&
    openssl x509 -req -in "$work/server.csr" -CA "$tls/ca.pem" -CAkey "$dir/ca-key.pem" -CAcreateserial \
        -days 825 -extfile "$work/ext" -out "$tls/server.pem" 2> /dev/null || { echo 'tls.sh: openssl failed' >&2; exit 1; }
chmod 644 "$tls/ca.pem" "$tls/server.pem" "$tls/server-key.pem"
echo "test CA and certificate made in .secrets/tls"
