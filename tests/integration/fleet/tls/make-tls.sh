#!/usr/bin/env bash
# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# make-tls.sh <backend address>... - the fleet test's own CA, and the
# backend's certificate from it, into tests/integration/fleet/tls/out/:
#
#   ca.crt        the CA every machine of the fleet trusts (admin/ adds it
#                 to each machine's store, and takes it out again)
#   ca.key        its key: kept here, never copied anywhere
#   server.crt    the backend's certificate, for every address given (an
#   server.key    IP or a name), and localhost
#
#   tls/make-tls.sh 192.168.4.40
#
# The CA is made once and kept: running this again makes a new server
# certificate from the same CA, so the machines that trust it need nothing
# new. It lasts 30 days, the server certificate 30 days: a test CA, not
# one to keep.
set -eu
# Git Bash would take -subj /CN=... for a path and rewrite it: not that
# one argument (file paths are still translated for its openssl).
export MSYS2_ARG_CONV_EXCL=/CN
here=$(cd "$(dirname "$0")" && pwd)
out=$here/out
[ "$#" -ge 1 ] || { echo "usage: make-tls.sh <backend address>..." >&2; exit 64; }
mkdir -p "$out" && chmod 700 "$out"
if [ ! -f "$out/ca.key" ]; then
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 \
        -subj '/CN=Vigil fleet test CA' -keyout "$out/ca.key" -out "$out/ca.crt" \
        -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' -addext 'keyUsage=critical,keyCertSign,cRLSign' 2> /dev/null
    echo "made the CA: $out/ca.crt"
fi
san='DNS:localhost,IP:127.0.0.1'
for a in "$@"; do
    case $a in *[!0-9.]*) san="$san,DNS:$a" ;; *) san="$san,IP:$a" ;; esac
done
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=$1" \
    -keyout "$out/server.key" -out "$out/server.csr" 2> /dev/null
printf 'subjectAltName=%s\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\n' "$san" > "$out/server.ext"
openssl x509 -req -in "$out/server.csr" -CA "$out/ca.crt" -CAkey "$out/ca.key" -CAcreateserial \
    -days 30 -extfile "$out/server.ext" -out "$out/server.crt" 2> /dev/null
rm -f "$out/server.csr" "$out/server.ext"
chmod 600 "$out/ca.key" "$out/server.key"
chmod 644 "$out/ca.crt" "$out/server.crt"
echo "made the backend's certificate for $san"
openssl x509 -in "$out/ca.crt" -noout -fingerprint -sha256 | sed 's/^/CA /'
