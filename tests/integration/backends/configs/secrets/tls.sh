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
# 127.0.0.1 (and constrained to those names), for the secret stores in
# compose.secrets.yaml and the sources in compose.sources.yaml. Made once and
# kept, so a store restarted later still has the certificate Vigil trusts.
# scripts/start.sh runs it before starting a store.
#
#   bash configs/secrets/tls.sh
#
# In .secrets/, which is git-ignored:
#   ca-key.pem     the CA's key, never mounted into a container
#   tls/ca.pem     the CA: Vigil's ca_file, and on other test hosts too
#   tls/server.pem, tls/server-key.pem   the stores' certificate and key
#   tls/server.p12  the same, as PKCS#12, for Lowkey Vault
#
# The server key is readable by all (0644): the containers run as uid 100,
# not as you. It is a test key for 127.0.0.1, worth nothing anywhere else.
# Delete .secrets/ to start again with a new CA (then scripts/reset.sh the
# stores too, whose unseal keys are kept there).

set -u
here=$(cd "$(dirname "$0")" && pwd)
dir=$(cd "$here/../.." && pwd)/.secrets
tls=$dir/tls

command -v openssl > /dev/null 2>&1 || { echo 'tls.sh needs openssl' >&2; exit 1; }

# The same certificate and key as PKCS#12, for Lowkey Vault, a Java server
# (password vigil-test: a test key, worth nothing anywhere else).
p12() {
    [ -f "$tls/server.p12" ] && return 0
    openssl pkcs12 -export -in "$tls/server.pem" -inkey "$tls/server-key.pem" -name lowkey-vault \
        -passout pass:vigil-test -out "$tls/server.p12" 2> /dev/null && chmod 644 "$tls/server.p12" ||
        { echo 'tls.sh: openssl could not make server.p12' >&2; exit 1; }
}

if [ -f "$tls/ca.pem" ] && [ -f "$tls/server.pem" ] && [ -f "$tls/server-key.pem" ]; then
    p12
    exit 0
fi
mkdir -p "$tls" && chmod 700 "$dir" || exit 1

work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
printf 'basicConstraints = critical, CA:FALSE\nkeyUsage = critical, digitalSignature, keyEncipherment\nextendedKeyUsage = serverAuth\nsubjectAltName = DNS:localhost, IP:127.0.0.1\n' > "$work/ext"

# Name constraints: the CA can vouch for localhost and 127.0.0.1 and nothing
# else, so a machine that trusts it (Windows' store, for the https source
# tests) could never be fooled about a real site, even if its key leaked.
(umask 077 && openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj '/CN=Vigil test CA' \
    -addext 'basicConstraints = critical, CA:TRUE' -addext 'keyUsage = critical, keyCertSign, cRLSign' \
    -addext 'nameConstraints = critical, permitted;DNS:localhost, permitted;IP:127.0.0.1/255.255.255.255' \
    -keyout "$dir/ca-key.pem" -out "$tls/ca.pem" 2> /dev/null) &&
    openssl req -newkey rsa:2048 -nodes -subj '/CN=localhost' -keyout "$tls/server-key.pem" -out "$work/server.csr" 2> /dev/null &&
    openssl x509 -req -in "$work/server.csr" -CA "$tls/ca.pem" -CAkey "$dir/ca-key.pem" -CAcreateserial \
        -days 825 -extfile "$work/ext" -out "$tls/server.pem" 2> /dev/null || { echo 'tls.sh: openssl failed' >&2; exit 1; }
chmod 644 "$tls/ca.pem" "$tls/server.pem" "$tls/server-key.pem"
p12
echo "test CA and certificate made in .secrets/tls"
