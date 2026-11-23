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
# run-tomcat.sh - the tomcat pack against real Tomcats with trouble on
# purpose, with its evidence kept like the other runs'.
#
#   scripts/run-tomcat.sh
#
# It makes a TLS certificate from a CA of its own and a JMX password of the
# run's own, fetches the apps' libraries (H2, HikariCP, SLF4J's API, each
# checked against its SHA-256 below), and starts compose.tomcat.yaml's
# Tomcats: 9.0, 10.1 and 11.0. Then trouble, on each: sessions past the
# shop's limit, pages that fail, every connection of its three pools held,
# its shared Executor's threads all held with requests queued behind them,
# the admin connector's threads all held, every held request stuck past the
# valve's 5 seconds, and an app that cannot start. Every job of the pack is
# run and what it reads is checked; then tests/integration/service-packs.sh
# runs the pack through Vigil (enable, the secret line, every job, a wrong
# password, a certificate it cannot trust, a server that is down); then
# every job again on a JRE. The Tomcats are taken down at the end.
#
# The pack is built as a release builds it: its jar compiled by
# tools/release/client-jar.sh, with a JDK 17 or later.
#
# VIGIL_IT_TOMCAT_JRE=<folder>: a JRE (11 or later, no compiler) to run
# every job on as well. VIGIL_IT_TOMCAT_JDK=<folder>: the JDK (17 or later)
# that compiles the probe, when JAVA_HOME has none and javac is not on the
# PATH. VIGIL_IT_TOMCAT_HOLD=<file>: at the end, the Tomcats are kept up,
# with the JMX password and the CA in <file>.d/ (this account's only), for
# the tests of other machines (macOS, Windows), until <file> is deleted.

set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/common.sh"

command -v java > /dev/null 2>&1 || die 'java not found: the pack runs the probe with Java 11 or later'
file=compose.tomcat.yaml
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-tomcat-it.XXXXXX") || exit 1
root=$work/none
export TOMCAT_TLS_DIR=$work/tls TOMCAT_LIB_DIR=$work/lib
dc() { docker compose -p vigil-tomcat --project-directory "$bk_dir" -f "$bk_dir/$file" "$@"; }
pw=$(openssl rand -hex 16)
kspw=$(openssl rand -hex 16)
export TOMCAT_JMX_PASSWORD=$pw TOMCAT_KS_PASSWORD=$kspw
trap 'dc down -v > /dev/null 2>&1; evidence_save "$pw" "$kspw"; rm -rf "$work"' EXIT

# The Tomcats' certificate, from a CA of this run's own, naming localhost and
# 127.0.0.1; and another CA, that signed nothing here.
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

# The apps' libraries, from Maven Central, each checked.
lib=$work/lib
mkdir -p "$lib"
while read -r path sum; do
    f=$lib/${path##*/}
    curl -sfL --max-time 120 -o "$f" "https://repo1.maven.org/maven2/$path" || die "cannot fetch $path"
    [ "$(sha256sum < "$f" | cut -c1-64)" = "$sum" ] || die "$path does not match its SHA-256"
done << 'EOF'
com/h2database/h2/2.3.232/h2-2.3.232.jar 8dae62d22db8982c3dcb3826edb9c727c5d302063a67eef7d63d82de401f07d3
com/zaxxer/HikariCP/5.1.0/HikariCP-5.1.0.jar a47a6ee62379694ee52c30036f0931b72f9aee2a801d590341ed82bd839e2134
org/slf4j/slf4j-api/2.0.16/slf4j-api-2.0.16.jar a12578dde1ba00bd9b816d388a0b879928d00bab3c83c240f7013bf4196c579a
EOF
chmod 644 "$lib"/*.jar

evidence_start pack-tomcat "$bk_dir/$file" "$0" "$@"
# The pack as a release builds it: its jar compiled and its digest in the scripts.
pack=$work/pack
mkdir -p "$pack" && cp "$bk_repo/packs/tomcat/pack.config" "$bk_repo/packs/tomcat/linux"/* "$pack/" || die 'cannot copy the pack'
JAVA_HOME=${VIGIL_IT_TOMCAT_JDK:-${JAVA_HOME-}} bash "$bk_repo/tools/release/client-jar.sh" "$pack" > "$work/jars.log" 2>&1 ||
    { cat "$work/jars.log"; die 'cannot build the pack'"'"'s jar'; }
sed 's/^client-jar: [^ ]*\/\(_[a-z]*\.jar\)/jar      \1/' "$work/jars.log"
printf 'java     %s\n' "$(java -version 2>&1 | head -n 1)"
[ -z "${VIGIL_IT_TOMCAT_JRE-}" ] || printf 'jre      %s (%s)\n' "$("$VIGIL_IT_TOMCAT_JRE/bin/java" -version 2>&1 | head -n 1)" "$VIGIL_IT_TOMCAT_JRE"
printf 'libs     %s\n' "$(cd "$lib" && ls | tr '\n' ' ' | sed 's/ $//')"

dc up -d > "$work/up.log" 2>&1 || { cat "$work/up.log"; die 'the Tomcats would not start'; }
for _ in $(seq 1 60); do
    up=0
    for p in 18091 18093 18095; do [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$p/shop/" 2> /dev/null)" = 200 ] && up=$((up + 1)); done
    [ "$up" -eq 3 ] && break
    sleep 3
done
[ "$up" -eq 3 ] || { dc logs --tail 30; die "only $up of 3 Tomcats answer"; }
printf 'tomcats  %s\n' "$(dc ps --format '{{.Service}} {{.Image}}' | sort | tr '\n' ';' | sed 's/;$//; s/;/; /g')"

say() { printf '\n# %s\n' "$*"; }
pass=0 fail=0
check() {
    if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; else fail=$((fail + 1)); printf '  FAIL  %s: expected [%s] actual [%s]\n' "$1" "$2" "$3"; fi
}
# The value of metric $2 in job $1's output (kept in $work/<job>.out), in a line matching $3.
val() { grep -E "^metric $2 [^ ]+ .*$3" "$work/$1.out" | head -n 1 | awk '{ print $3 }'; }
# yes when that value is at least $4.
least() { awk -v v="$(val "$1" "$2" "$3")" -v a="$4" 'BEGIN { print (v ~ /^[0-9.]+$/ && v + 0 >= a) ? "yes" : "no [" v "]" }'; }

say "Trouble, on each Tomcat."
# http (the Executor, 8 threads): every connection of the shop's two pools
# held (4 each), then 4 requests queued behind them. admin (6 threads): the
# HikariCP pool's 3 held, and 3 slow pages. All held 240 s: stuck past 5.
for p in 18091 18093 18095; do
    a=$((p + 1))
    for i in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$p/shop/index.jsp"; done
    for i in 1 2 3; do curl -s -o /dev/null "http://127.0.0.1:$p/shop/fail.jsp"; done
    for i in 1 2 3 4; do
        curl -s -o /dev/null --max-time 300 "http://127.0.0.1:$p/shop/jdbc.jsp?db=shop&s=240" &
        curl -s -o /dev/null --max-time 300 "http://127.0.0.1:$p/shop/jdbc.jsp?db=orders&s=240" &
    done
    for i in 1 2 3; do
        curl -s -o /dev/null --max-time 300 "http://127.0.0.1:$a/shop/jdbc.jsp?db=hikari&s=240" &
        curl -s -o /dev/null --max-time 300 "http://127.0.0.1:$a/shop/slow.jsp?s=240" &
    done
    sleep 2
    for i in 1 2 3 4; do curl -s -o /dev/null --max-time 300 "http://127.0.0.1:$p/shop/index.jsp" & done
done
printf 'sent     on each: 50 visits (a session each, past the limit of 40), 3 failing pages, 8 pool holds and 4 queued on http, 3 pool holds and 3 slow pages on admin\n'
sleep 15

targets='tc9: jmxs=localhost:19301; tc10: jmxs=localhost:19302; tc11: jmxs=localhost:19303'
export TOMCAT_JMX=$targets TOMCAT_JMX_USER=monitor TOMCAT_JMX_PASSWORD=$pw TOMCAT_CACERT=$tls/ca.crt
say "Every job, as the pack's scripts print it."
jobs=$(sed -n 's/^\[job\.\(.*\)\]$/\1/p' "$pack/pack.config")
for j in $jobs; do
    printf '\n$ bash packs/tomcat/%s.sh\n' "$j"
    bash "$pack/$j.sh" > "$work/$j.out" 2> "$work/$j.err"
    printf 'exit %s\n' "$?" >> "$work/$j.err"
    head -n 70 "$work/$j.out"
    [ "$(wc -l < "$work/$j.out")" -gt 70 ] && printf '... (%s lines)\n' "$(wc -l < "$work/$j.out" | tr -d ' ')"
    grep -v '^exit 0$' "$work/$j.err"
done

say "What they read."
for j in $jobs; do check "tomcat: $j runs" 'exit 0' "$(tail -n 1 "$work/$j.err")"; done
for t in tc9:9.0 tc10:10.1 tc11:11.0; do
    n=${t%%:*} v=${t#*:}
    check "$n: answers over TLS with a password" 1 "$(val status jmx_up "tomcat=$n ")"
    check "$n: its version, $v" yes "$(grep -qE "^metric version 1 tomcat=$n .* version=${v//./\\.}\.[0-9]+" "$work/status.out" && echo yes || echo no)"
    check "$n: the server is started" 1 "$(val status up "tomcat=$n ")"
    check "$n: both connectors" '1 1' "$(grep -E "^metric connector_up [^ ]+ tomcat=$n " "$work/status.out" | awk '{ print $3 }' | tr '\n' ' ' | sed 's/ $//')"
    check "$n: requests, counted" yes "$(least requests requests_count "tomcat=$n .*name=http-nio-.*8080" 50)"
    check "$n: and those that failed" yes "$(least requests errors_count "tomcat=$n .*name=http-nio-.*8080" 13)"
    check "$n: the Executor's threads, all busy" 8 "$(val threads executor_busy "tomcat=$n ")"
    check "$n: of 8" 8 "$(val threads executor_max_threads "tomcat=$n ")"
    check "$n: requests queued behind them" yes "$(least threads executor_queue "tomcat=$n " 1)"
    check "$n: the admin connector's threads, all busy" 6 "$(val threads busy "tomcat=$n .*name=http-nio-.*8081")"
    check "$n: of 6" 6 "$(val threads max_threads "tomcat=$n .*name=http-nio-.*8081")"
    check "$n: requests running now, the longest first" yes "$(grep -E "^metric running_seconds [^ ]+ tomcat=$n " "$work/inflight.out" | awk '{ print $3 }' | head -n 14 |
        awk 'NR > 1 && $1 > p { bad = 1 } { p = $1; n++ } END { print (n >= 10 && !bad) ? "yes" : "no [" n "]" }')"
    check "$n: stuck threads" yes "$(least inflight stuck_threads "tomcat=$n " 10)"
    check "$n: the shop is started" 1 "$(val apps up "tomcat=$n .*name=//localhost/shop")"
    check "$n: the app that cannot start is not" 0 "$(val apps up "tomcat=$n .*name=//localhost/broken")"
    check "$n: the shop's sessions, at their limit" 40 "$(val sessions most "tomcat=$n .*context=/shop")"
    check "$n: the limit" 40 "$(val sessions limit "tomcat=$n .*context=/shop")"
    check "$n: and those refused for it" yes "$(least sessions rejected_count "tomcat=$n .*context=/shop" 10)"
    check "$n: the JSPs' time" yes "$(least servlets processing_seconds "tomcat=$n .*name=jsp" 0.01)"
    check "$n: DBCP's pool, every connection in use" 4 "$(val jdbc active "tomcat=$n .*name=jdbc/shop")"
    check "$n: of 4" 4 "$(val jdbc max "tomcat=$n .*name=jdbc/shop")"
    check "$n: Tomcat's JDBC pool, every connection in use" 4 "$(val jdbc active "tomcat=$n .*name=jdbc/orders")"
    check "$n: and its connections borrowed" yes "$(least jdbc borrowed_count "tomcat=$n .*name=jdbc/orders" 4)"
    check "$n: HikariCP's pool, every connection in use" 3 "$(val jdbc hikari_active "tomcat=$n ")"
    check "$n: the shop's JSPs, loaded" yes "$(least cache jsps "tomcat=$n .*WebModule=//localhost/shop" 3)"
    check "$n: its resource cache, looked in" yes "$(least cache lookups_count "tomcat=$n .*context=/shop" 1)"
done
check 'tomcat: the shop is up longer than it took to start' yes "$(least apps uptime_seconds 'tomcat=tc11 .*name=//localhost/shop' 30)"

say "The pack through Vigil."
export VIGIL_IT_PROBE_PACK=tomcat VIGIL_IT_PROBE_PACK_DIR=$pack VIGIL_IT_PROBE_TARGETS=$targets VIGIL_IT_PROBE_USER=monitor \
    VIGIL_IT_PROBE_PASSWORD=$pw VIGIL_IT_PROBE_CACERT=$tls/ca.crt VIGIL_IT_PROBE_EXPECT=tomcat_threads_executor_busy
unset TOMCAT_JMX TOMCAT_JMX_USER TOMCAT_CACERT
TOMCAT_JMX_PASSWORD='' bash "$bk_repo/tests/integration/service-packs.sh"
rc=$?
export TOMCAT_JMX=$targets TOMCAT_JMX_USER=monitor TOMCAT_CACERT=$tls/ca.crt

say "The jar: refused when changed, and on a JRE."
cp -R "$pack" "$work/bad" && printf 'x' | dd of="$work/bad/_probe.jar" bs=1 seek=100 conv=notrunc 2> /dev/null
out=$(bash "$work/bad/status.sh" 2>&1)
check 'tomcat: a probe changed by one byte is not run' 1 "$?"
printf '        %s\n' "$out"
check 'tomcat: and says why' yes "$(printf '%s' "$out" | grep -q 'does not match the digest in this script, so it is not run' && echo yes || echo no)"
if [ -n "${VIGIL_IT_TOMCAT_JRE-}" ]; then
    check 'tomcat: the JRE has no compiler' no "$([ -x "$VIGIL_IT_TOMCAT_JRE/bin/javac" ] && echo yes || echo no)"
    bad=''
    for j in $jobs; do
        JAVA_HOME=$VIGIL_IT_TOMCAT_JRE bash "$pack/$j.sh" > "$work/jre-$j.out" 2>&1 || bad="$bad $j"
    done
    check 'tomcat: every job runs on the JRE' '' "$bad"
    check 'tomcat: and reads the same Tomcats' "$(grep -c '^metric jmx_up 1 ' "$work/status.out")" "$(grep -c '^metric jmx_up 1 ' "$work/jre-status.out")"
fi
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || rc=1

if [ -n "${VIGIL_IT_TOMCAT_HOLD-}" ]; then
    hd=$VIGIL_IT_TOMCAT_HOLD.d
    rm -rf "$hd" && (umask 077 && mkdir -p "$hd" && printf '%s' "$pw" > "$hd/pw") && cp "$tls/ca.crt" "$hd/ca.crt"
    : > "$VIGIL_IT_TOMCAT_HOLD"
    say "Kept up for other machines' tests until $VIGIL_IT_TOMCAT_HOLD is deleted."
    while [ -e "$VIGIL_IT_TOMCAT_HOLD" ]; do sleep 5; done
    rm -rf "$hd"
fi
exit $rc
