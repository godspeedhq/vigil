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
# run-jetty.sh - the jetty pack against real Jettys with trouble on purpose,
# with its evidence kept like the other runs'.
#
#   scripts/run-jetty.sh
#
# It makes a TLS certificate from a CA of its own and a JMX password of the
# run's own, and starts compose.jetty.yaml's Jettys: 9.4, 11.0, 12.0 and
# 12.1, each with 24 threads and a limit of 40 connections. Then trouble,
# on each: sessions, pages that fail, pages that are not there, and 45 slow
# requests held open: every thread busy, requests queued, the connection
# limit reached, the low resources monitor tripped (and on 12, the QoS
# handler's limit). Every job of the pack is run and what it reads is
# checked; then tests/integration/service-packs.sh runs the pack through
# Vigil; then every job again on a JRE. The Jettys are taken down at the end.
#
# VIGIL_IT_JETTY_JRE=<folder>: a JRE (11 or later, no compiler) to run every
# job on as well. VIGIL_IT_JETTY_JDK=<folder>: the JDK (17 or later) that
# compiles the probe, when JAVA_HOME has none. VIGIL_IT_JETTY_HOLD=<file>:
# at the end, the Jettys are kept up, with the JMX password and the CA in
# <file>.d/ (this account's only), for other machines' tests, until <file>
# is deleted.

set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/common.sh"

command -v java > /dev/null 2>&1 || die 'java not found: the pack runs the probe with Java 11 or later'
file=compose.jetty.yaml
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-jetty-it.XXXXXX") || exit 1
root=$work/none
export JETTY_TLS_DIR=$work/tls
dc() { docker compose -p vigil-jetty --project-directory "$bk_dir" -f "$bk_dir/$file" "$@"; }
pw=$(openssl rand -hex 16)
kspw=$(openssl rand -hex 16)
export JETTY_JMX_PASSWORD=$pw JETTY_KS_PASSWORD=$kspw
trap 'dc down -v > /dev/null 2>&1; evidence_save "$pw" "$kspw"; rm -rf "$work"' EXIT

tls=$work/tls
mkdir -p "$tls"
(
    cd "$tls" || exit 1
    openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -days 2 -subj '/CN=Vigil test CA' > /dev/null 2>&1 &&
        openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr -subj '/CN=localhost' > /dev/null 2>&1 &&
        printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\n' > server.ext &&
        openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 2 -extfile server.ext > /dev/null 2>&1 &&
        KS=$kspw openssl pkcs12 -export -in server.crt -inkey server.key -name jmx -out server.p12 -passout env:KS > /dev/null 2>&1 &&
        chmod 644 server.p12 ca.crt
) || die 'cannot make the test certificate'

evidence_start pack-jetty "$bk_dir/$file" "$0" "$@"
pack=$work/pack
mkdir -p "$pack" && cp "$bk_repo/packs/jetty/pack.config" "$bk_repo/packs/jetty/linux"/* "$pack/" || die 'cannot copy the pack'
JAVA_HOME=${VIGIL_IT_JETTY_JDK:-${JAVA_HOME-}} bash "$bk_repo/tools/release/client-jar.sh" "$pack" > "$work/jars.log" 2>&1 ||
    { cat "$work/jars.log"; die 'cannot build the pack'"'"'s jar'; }
sed 's/^client-jar: [^ ]*\/\(_[a-z]*\.jar\)/jar      \1/' "$work/jars.log"
printf 'java     %s\n' "$(java -version 2>&1 | head -n 1)"
[ -z "${VIGIL_IT_JETTY_JRE-}" ] || printf 'jre      %s (%s)\n' "$("$VIGIL_IT_JETTY_JRE/bin/java" -version 2>&1 | head -n 1)" "$VIGIL_IT_JETTY_JRE"

dc up -d > "$work/up.log" 2>&1 || { cat "$work/up.log"; die 'the Jettys would not start'; }
for _ in $(seq 1 60); do
    up=0
    for p in 18101 18102 18103 18104; do [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$p/shop/" 2> /dev/null)" = 200 ] && up=$((up + 1)); done
    [ "$up" -eq 4 ] && break
    sleep 3
done
[ "$up" -eq 4 ] || { dc logs --tail 30; die "only $up of 4 Jettys answer"; }
printf 'jettys   %s\n' "$(dc ps --format '{{.Service}} {{.Image}}' | sort | tr '\n' ';' | sed 's/;$//; s/;/; /g')"

say() { printf '\n# %s\n' "$*"; }
pass=0 fail=0
check() {
    if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; else fail=$((fail + 1)); printf '  FAIL  %s: expected [%s] actual [%s]\n' "$1" "$2" "$3"; fi
}
val() { grep -E "^metric $2 [^ ]+ .*$3" "$work/$1.out" | head -n 1 | awk '{ print $3 }'; }
least() { awk -v v="$(val "$1" "$2" "$3")" -v a="$4" 'BEGIN { print (v ~ /^[0-9.]+$/ && v + 0 >= a) ? "yes" : "no [" v "]" }'; }

say "Trouble, on each Jetty."
for p in 18101 18102 18103 18104; do
    for i in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$p/shop/index.jsp"; done
    for i in 1 2 3; do
        curl -s -o /dev/null "http://127.0.0.1:$p/shop/fail.jsp"
        curl -s -o /dev/null "http://127.0.0.1:$p/nope"
        curl -s -o /dev/null "http://127.0.0.1:$p/broken/"
    done
    for i in $(seq 1 45); do curl -s -o /dev/null --max-time 300 "http://127.0.0.1:$p/shop/slow.jsp?s=240" & done
done
printf 'sent     on each: 50 visits (a session each), 3 failing pages, 3 not there, 3 to the app that failed to start, 45 slow requests held 240 s\n'
sleep 20

targets='j94: jmxs=localhost:19311; j11: jmxs=localhost:19312; j120: jmxs=localhost:19313; j121: jmxs=localhost:19314'
export JETTY_JMX=$targets JETTY_JMX_USER=monitor JETTY_JMX_PASSWORD=$pw JETTY_CACERT=$tls/ca.crt
say "Every job, as the pack's scripts print it."
jobs=$(sed -n 's/^\[job\.\(.*\)\]$/\1/p' "$pack/pack.config")
for j in $jobs; do
    printf '\n$ bash packs/jetty/%s.sh\n' "$j"
    bash "$pack/$j.sh" > "$work/$j.out" 2> "$work/$j.err"
    printf 'exit %s\n' "$?" >> "$work/$j.err"
    cat "$work/$j.out"
    grep -v '^exit 0$' "$work/$j.err"
done

say "What they read."
for j in $jobs; do check "jetty: $j runs" 'exit 0' "$(tail -n 1 "$work/$j.err")"; done
for t in j94:9.4 j11:11.0 j120:12.0 j121:12.1; do
    n=${t%%:*} v=${t#*:}
    check "$n: answers over TLS with a password" 1 "$(val status jmx_up "jetty=$n ")"
    check "$n: its version, $v" yes "$(grep -qE "^metric version 1 jetty=$n .* version=${v//./\\.}\.[0-9]+" "$work/status.out" && echo yes || echo no)"
    check "$n: the server is started" 1 "$(val status up "jetty=$n ")"
    check "$n: the shop is started" 1 "$(val status app_up "jetty=$n .*context=_?shop")"
    printf '        %s: the app that failed to start reads app_up %s (Jetty keeps it STARTED, answering 503)\n' "$n" "$(val status app_up "jetty=$n .*context=_?broken")"
    check "$n: requests, counted" yes "$(least requests requests_count "jetty=$n " 50)"
    check "$n: responses 5xx (the failed app's 503s)" yes "$(least requests responses_5xx_count "jetty=$n " 3)"
    check "$n: responses 4xx" yes "$(least requests responses_4xx_count "jetty=$n " 3)"
    check "$n: requests active now" yes "$(least requests active "jetty=$n " 10)"
    check "$n: the slowest, in seconds" yes "$(least requests slowest_seconds "jetty=$n " 0.001)"
    check "$n: threads, 24 at most" 24 "$(val threads max_threads "jetty=$n ")"
    case $n in
        j94 | j11)
            check "$n: pages that threw" yes "$(least requests thrown_count "jetty=$n " 3)"
            check "$n: every thread busy but what it keeps" yes "$(least threads busy "jetty=$n " 20)"
            check "$n: jobs queued for a thread" yes "$(least threads queue "jetty=$n " 1)"
            check "$n: low on threads" 1 "$(val threads low_on_threads "jetty=$n ")"
            check "$n: low on resources" 1 "$(val status low_on_resources "jetty=$n ")"
            ;;
        *)
            check "$n: pages that threw, as 5xx too" yes "$(least requests responses_5xx_count "jetty=$n " 6)"
            check "$n: the QoS limit" 16 "$(val connections qos_max "jetty=$n ")"
            check "$n: requests suspended for it" yes "$(least connections qos_suspended "jetty=$n " 10)"
            check "$n: so threads are left" yes "$(least threads busy "jetty=$n " 16)"
            ;;
    esac
    check "$n: connections open" yes "$(least connections open "jetty=$n " 20)"
    check "$n: the connection limit" 40 "$(val connections limit "jetty=$n ")"
    check "$n: connections it counts" yes "$(least connections limited "jetty=$n " 20)"
    check "$n: sessions" yes "$(least sessions most "jetty=$n .*context=_?shop" 40)"
    check "$n: its byte buffers" yes "$(least buffers direct_bytes "jetty=$n " 1)"
done

say "The pack through Vigil."
export VIGIL_IT_PROBE_PACK=jetty VIGIL_IT_PROBE_PACK_DIR=$pack VIGIL_IT_PROBE_TARGETS=$targets VIGIL_IT_PROBE_USER=monitor \
    VIGIL_IT_PROBE_PASSWORD=$pw VIGIL_IT_PROBE_CACERT=$tls/ca.crt VIGIL_IT_PROBE_EXPECT=jetty_threads_busy
unset JETTY_JMX JETTY_JMX_USER JETTY_CACERT
JETTY_JMX_PASSWORD='' bash "$bk_repo/tests/integration/service-packs.sh"
rc=$?
export JETTY_JMX=$targets JETTY_JMX_USER=monitor JETTY_CACERT=$tls/ca.crt

say "The jar: refused when changed, and on a JRE."
cp -R "$pack" "$work/bad" && printf 'x' | dd of="$work/bad/_probe.jar" bs=1 seek=100 conv=notrunc 2> /dev/null
out=$(bash "$work/bad/status.sh" 2>&1)
check 'jetty: a probe changed by one byte is not run' 1 "$?"
printf '        %s\n' "$out"
if [ -n "${VIGIL_IT_JETTY_JRE-}" ]; then
    check 'jetty: the JRE has no compiler' no "$([ -x "$VIGIL_IT_JETTY_JRE/bin/javac" ] && echo yes || echo no)"
    bad=''
    for j in $jobs; do JAVA_HOME=$VIGIL_IT_JETTY_JRE bash "$pack/$j.sh" > "$work/jre-$j.out" 2>&1 || bad="$bad $j"; done
    check 'jetty: every job runs on the JRE' '' "$bad"
    check 'jetty: and reads the same Jettys' "$(grep -c '^metric jmx_up 1 ' "$work/status.out")" "$(grep -c '^metric jmx_up 1 ' "$work/jre-status.out")"
fi
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || rc=1

if [ -n "${VIGIL_IT_JETTY_HOLD-}" ]; then
    hd=$VIGIL_IT_JETTY_HOLD.d
    rm -rf "$hd" && (umask 077 && mkdir -p "$hd" && printf '%s' "$pw" > "$hd/pw") && cp "$tls/ca.crt" "$hd/ca.crt"
    : > "$VIGIL_IT_JETTY_HOLD"
    say "Kept up for other machines' tests until $VIGIL_IT_JETTY_HOLD is deleted."
    while [ -e "$VIGIL_IT_JETTY_HOLD" ]; do sleep 5; done
    rm -rf "$hd"
fi
exit $rc
