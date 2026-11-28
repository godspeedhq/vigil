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
# run-tls.sh - the tls pack against a certificate for each kind of trouble,
# with its evidence kept like the other runs'.
#
#   scripts/run-tls.sh
#
# It makes a CA of its own, an intermediate under it, and from them a
# certificate good for a year; one that expires in 5 days; one expired; one
# not valid yet; one self-signed; one for another name; one from the
# intermediate, served without it; and a wildcard. nginx serves each for
# its name (SNI), and TLS 1.3 only and TLS 1.2 only on ports of their own;
# compose.tls.yaml adds a port that is not TLS and one that never answers.
# The job runs against them all, with the CA as TLS_CACERT, and what it read
# for each is checked. Then a renewal: a new certificate on disk, read
# before nginx reloads it and after. Then tests/integration/service-packs.sh
# runs the pack through Vigil. VIGIL_IT_TLS_HOLD (below) keeps it up for
# other machines' tests.

set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/common.sh"

command -v docker > /dev/null 2>&1 || die 'docker not found: nginx runs in a container'
for p in curl openssl; do command -v "$p" > /dev/null 2>&1 || die "$p not found"; done
file=compose.tls.yaml
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-tls-it.XXXXXX") || exit 1
root=$work/none
export TLS_CONF=$work/nginx.conf TLS_CERTS=$work/certs
c=$TLS_CERTS
mkdir -p "$c"
dc() { docker compose -p vigil-tls --project-directory "$bk_dir" -f "$bk_dir/$file" "$@"; }
trap 'dc down -v > /dev/null 2>&1; evidence_save; rm -rf "$work"' EXIT

# The CA, and an intermediate under it.
ca_ext='basicConstraints=critical,CA:TRUE
keyUsage=critical,keyCertSign,cRLSign'
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$c/ca.key" -out "$c/ca.pem" -days 3650 \
    -subj '/CN=Vigil Test Root CA' -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" > /dev/null 2>&1 || die 'could not make the CA'
openssl req -new -newkey rsa:2048 -nodes -keyout "$c/inter.key" -out "$c/inter.csr" -subj '/CN=Vigil Test Intermediate' > /dev/null 2>&1
openssl x509 -req -in "$c/inter.csr" -CA "$c/ca.pem" -CAkey "$c/ca.key" -set_serial "0x$(openssl rand -hex 8)" -days 3650 \
    -out "$c/inter.pem" -extfile <(printf '%s\n' "$ca_ext") > /dev/null 2>&1 || die 'could not make the intermediate'
# leaf <file> <signer> <names, comma-separated> <dates: -days N, or
# -not_before/-not_after>: a server certificate.
leaf() {
    local f=$1 signer=$2 names=$3 first
    shift 3
    first=${names%%,*}
    openssl req -new -newkey rsa:2048 -nodes -keyout "$c/$f.key" -out "$c/$f.csr" -subj "/CN=$first" > /dev/null 2>&1
    openssl x509 -req -in "$c/$f.csr" -CA "$c/$signer.pem" -CAkey "$c/$signer.key" -set_serial "0x$(openssl rand -hex 8)" "$@" \
        -out "$c/$f.crt" -extfile <(printf 'basicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\nsubjectAltName=%s\n' \
        "$(printf '%s' "$names" | sed 's/[^,]*/DNS:&/g')") > /dev/null 2>&1 || die "could not make $f's certificate"
}
leaf good ca good.test,tls13.test,tls12.test -days 365
leaf soon ca soon.test -days 5
leaf expired ca expired.test -not_before 20250101000000Z -not_after 20250301000000Z
leaf future ca future.test -not_before 20990101000000Z -not_after 20991231000000Z
leaf wrong ca other.test -days 365
leaf chain inter chain.test -days 365
leaf wild ca '*.apps.test' -days 365
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$c/self.key" -out "$c/self.crt" -days 365 -subj '/CN=self.test' \
    -addext 'subjectAltName=DNS:self.test' > /dev/null 2>&1 || die 'could not make the self-signed certificate'
rm -f "$c"/*.csr
chmod 755 "$c"
chmod 644 "$c"/*
site() { printf '    server { listen %s ssl; server_name %s; ssl_certificate /certs/%s.crt; ssl_certificate_key /certs/%s.key;%s return 200 "%s\\n"; }\n' "$1" "$2" "$3" "$3" "${4-}" "$2"; }
{
    printf 'events {}\nhttp {\n    access_log off;\n'
    printf '    server { listen 8443 ssl default_server; server_name good.test; ssl_certificate /certs/good.crt; ssl_certificate_key /certs/good.key; return 200 "good\\n"; }\n'
    site 8443 soon.test soon
    site 8443 expired.test expired
    site 8443 future.test future
    site 8443 self.test self
    site 8443 wrong.test wrong
    site 8443 chain.test chain
    site 8443 '*.apps.test' wild
    site 8444 tls13.test good ' ssl_protocols TLSv1.3;'
    site 8445 tls12.test good ' ssl_protocols TLSv1.2;'
    printf '    server { listen 8446; return 200 "plain\\n"; }\n}\n'
} > "$TLS_CONF"
chmod 644 "$TLS_CONF"
evidence_start pack-tls "$bk_dir/$file" "$0" "$@"
pack=$bk_repo/packs/tls/linux
[ "$(uname -s)" = Darwin ] && pack=$bk_repo/packs/tls/macos

dc up -d > "$work/up.log" 2>&1 || { tail -n 20 "$work/up.log"; die 'nginx would not start'; }
for _ in $(seq 1 30); do curl -s -o /dev/null http://127.0.0.1:18546/ && break; sleep 1; done
curl -s -o /dev/null http://127.0.0.1:18546/ || { dc logs --tail 20; die 'nginx never answered'; }
printf 'servers  %s\n' "$(dc ps --format '{{.Service}} {{.Image}}' | sort | tr '\n' ';' | sed 's/;$//; s/;/; /g')"
printf 'openssl  %s\n' "$(openssl version)"
echo 'certs    from a CA of its own: good (a year), soon (5 days), expired, future (not valid yet), self-signed, wrong (for other.test), chain (from an intermediate, served without it), a wildcard (*.apps.test)'

w=127.0.0.1:18543
targets="$w/good.test $w/soon.test $w/expired.test $w/future.test $w/self.test $w/wrong.test $w/chain.test $w/a.apps.test $w/a.b.apps.test 127.0.0.1:18544/tls13.test 127.0.0.1:18545/tls12.test 127.0.0.1:18546 127.0.0.1:18547 127.0.0.1:18549 no-such-host.invalid"
failing=10

say() { printf '\n# %s\n' "$*"; }
pass=0
fail=0
check() {
    if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; else fail=$((fail + 1)); printf '  FAIL  %s: expected [%s] actual [%s]\n' "$1" "$2" "$3"; fi
}
# val <metric> <target>: its value; tags <metric> <target>: its other tags.
val() { awk -v m="$1" -v t="target=$2" '$1 == "metric" && $2 == m && (t == "target=" ? NF == 3 : $4 == t) { print $3; exit }' "$work/certs.out"; }
tags() { awk -v m="$1" -v t="target=$2" '$1 == "metric" && $2 == m && $4 == t { $1 = $2 = $3 = $4 = ""; sub(/^ +/, ""); print; exit }' "$work/certs.out"; }
run() {
    printf '\n$ TLS_TARGETS=... TLS_CACERT=ca.pem TLS_TIMEOUT=5 bash packs/tls/linux/certs.sh%s\n' "${1:+   ($1)}"
    TLS_TARGETS=$targets TLS_CACERT=$c/ca.pem TLS_TIMEOUT=5 bash "$pack/certs.sh" > "$work/certs.out" 2> "$work/certs.err"
    printf 'exit %s\n' "$?" >> "$work/certs.err"
    cat "$work/certs.out"
    grep -v '^exit 0$' "$work/certs.err"
}

say "Every target, as the job prints it."
run
say "What it read."
check 'the job runs' 'exit 0' "$(tail -n 1 "$work/certs.err")"
check 'every target counted; those failing a check counted' "15 $failing" "$(val targets '') $(val targets_failed '')"
g=$w/good.test
check 'good: up, a year left, valid, trusted by the CA, the right name' '1 yes 1 1 1' "$(val up "$g") $(awk -v d="$(val cert_expires_days "$g")" 'BEGIN { print (d > 364 && d <= 365) ? "yes" : "no [" d "]" }') $(val cert_valid "$g") $(val cert_trusted "$g") $(val cert_name_ok "$g")"
check 'good: its issuer and subject; the handshake timed' 'issuer=Vigil_Test_Root_CA subject=good.test yes' "$(tags cert_info "$g" | cut -d' ' -f1-2) $(awk -v m="$(val handshake_ms "$g")" 'BEGIN { print (m > 0 && m < 5000) ? "yes" : "no [" m "]" }')"
check 'soon: under 5 days left, and nothing else wrong' 'yes 1 1 1' "$(awk -v d="$(val cert_expires_days "$w/soon.test")" 'BEGIN { print (d > 4 && d <= 5) ? "yes" : "no [" d "]" }') $(val cert_valid "$w/soon.test") $(val cert_trusted "$w/soon.test") $(val cert_name_ok "$w/soon.test")"
check 'the soonest is the expired one' "$(val cert_expires_days "$w/expired.test")" "$(val soonest_days '')"
check 'expired: below 0, not valid, not trusted, and why' 'yes 0 0 reason=certificate_has_expired' "$(awk -v d="$(val cert_expires_days "$w/expired.test")" 'BEGIN { print (d < 0) ? "yes" : "no" }') $(val cert_valid "$w/expired.test") $(val cert_trusted "$w/expired.test") $(tags cert_trusted "$w/expired.test")"
check 'future: not valid yet, and why' '0 reason=certificate_is_not_yet_valid' "$(val cert_valid "$w/future.test") $(tags cert_trusted "$w/future.test")"
check 'self-signed: within its dates, not trusted, and why' '1 0 reason=self-signed_certificate' "$(val cert_valid "$w/self.test") $(val cert_trusted "$w/self.test") $(tags cert_trusted "$w/self.test")"
check 'wrong: trusted, but not for the name asked' '1 0' "$(val cert_trusted "$w/wrong.test") $(val cert_name_ok "$w/wrong.test")"
check 'chain: the intermediate not sent, so not trusted, and why' '0 reason=unable_to_get_local_issuer_certificate' "$(val cert_trusted "$w/chain.test") $(tags cert_trusted "$w/chain.test")"
check 'the wildcard: one label, yes; two, no' '1 0' "$(val cert_name_ok "$w/a.apps.test") $(val cert_name_ok "$w/a.b.apps.test")"
check 'TLS 1.3 only, and 1.2 only: each agreed' 'protocol=TLSv1.3 protocol=TLSv1.2' "$(tags cert_info 127.0.0.1:18544/tls13.test | cut -d' ' -f3) $(tags cert_info 127.0.0.1:18545/tls12.test | cut -d' ' -f3)"
check 'not TLS, never answers, nothing listening, no such host: each up 0, and why' '0 reason=handshake_failed 0 reason=timeout 0 reason=refused 0 reason=no_such_host' "$(val up 127.0.0.1:18546) $(tags up 127.0.0.1:18546) $(val up 127.0.0.1:18547) $(tags up 127.0.0.1:18547) $(val up 127.0.0.1:18549) $(tags up 127.0.0.1:18549) $(val up no-such-host.invalid) $(tags up no-such-host.invalid)"
check 'without the CA, the good one is not trusted' '0' "$(TLS_TARGETS=$g bash "$pack/certs.sh" | awk '$2 == "cert_trusted" { print $3 }')"
check 'no targets: none counted, the run succeeding' '0 metric targets 0 metric targets_failed 0' "$(TLS_TARGETS= bash "$pack/certs.sh" > "$work/none.out" 2>&1; echo "$?" $(cat "$work/none.out"))"

say "A renewal: a new certificate for good.test on disk, for 90 days. nginx has not reloaded."
before=$(val cert_expires_days "$g")
leaf good ca good.test,tls13.test,tls12.test -days 90
chmod 644 "$c"/good.*
TLS_TARGETS=$g TLS_CACERT=$c/ca.pem bash "$pack/certs.sh" | tee "$work/renew1.out" | grep -E 'cert_expires_days|cert_trusted'
check 'renewed on disk, not loaded: clients still get the old one' yes "$(awk -v d="$(awk '$2 == "cert_expires_days" { print $3 }' "$work/renew1.out")" -v b="$before" 'BEGIN { print (d > 364 && d - b < 0.01) ? "yes" : "no [" d "]" }')"
say "nginx reloads."
dc exec -T web nginx -s reload > /dev/null 2>&1
sleep 2
TLS_TARGETS=$g TLS_CACERT=$c/ca.pem bash "$pack/certs.sh" | tee "$work/renew2.out" | grep -E 'cert_expires_days|cert_trusted'
check 'reloaded: the new one, 90 days' yes "$(awk -v d="$(awk '$2 == "cert_expires_days" { print $3 }' "$work/renew2.out")" 'BEGIN { print (d > 89 && d <= 90) ? "yes" : "no [" d "]" }')"

say "The pack through Vigil, against them all."
export VIGIL_IT_TLS=$targets VIGIL_IT_TLS_CACERT=$c/ca.pem VIGIL_IT_TLS_FAILED=$failing
bash "$bk_repo/tests/integration/service-packs.sh"
rc=$?
# VIGIL_IT_TLS_HOLD=<file>: the targets stay up for the tests of other
# machines, until <file> is deleted; the CA is copied beside it.
if [ -n "${VIGIL_IT_TLS_HOLD-}" ]; then
    cp "$c/ca.pem" "$VIGIL_IT_TLS_HOLD.ca.pem"
    : > "$VIGIL_IT_TLS_HOLD"
    printf 'hold     the targets stay up (18543 to 18547) until %s is deleted; the CA is %s.ca.pem\n' "$VIGIL_IT_TLS_HOLD" "$VIGIL_IT_TLS_HOLD"
    while [ -e "$VIGIL_IT_TLS_HOLD" ]; do sleep 5; done
fi

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && [ "$rc" -eq 0 ]
