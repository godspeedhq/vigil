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
# run-artemis.sh - the artemis pack against real Artemis brokers with
# trouble on purpose, with its evidence kept like the other runs'.
#
#   scripts/run-artemis.sh
#
# It makes a TLS certificate from a CA of its own, passwords of the run's
# own (the broker's admin, and monitor, a user of a role that may only
# read), each broker's etc-override (management.xml, users and roles, and
# workloads/artemis's broker.properties), and starts compose.artemis.yaml's
# brokers: 2.33, 2.40 and 2.44. Then trouble, on each, with Artemis's own
# producer and consumer: an address paging to disk, two smaller queues,
# messages that expire into ExpiryQueue, an address that blocks its
# producers, messages sent where no queue reads them, logins refused, and a
# slow consumer. Every job of the pack is run and what it reads is checked;
# then tests/integration/service-packs.sh runs the pack through Vigil, as
# monitor; then every job again on a JRE. The brokers are taken down at the
# end.
#
# VIGIL_IT_ARTEMIS_JRE, VIGIL_IT_ARTEMIS_JDK and VIGIL_IT_ARTEMIS_HOLD as
# run-tomcat.sh's.

set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/common.sh"

command -v java > /dev/null 2>&1 || die 'java not found: the pack runs the probe with Java 11 or later'
file=compose.artemis.yaml
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-artemis-it.XXXXXX") || exit 1
root=$work/none
export ARTEMIS_TLS_DIR=$work/tls ARTEMIS_ETC_DIR=$work/etc
dc() { docker compose -p vigil-artemis --project-directory "$bk_dir" -f "$bk_dir/$file" "$@"; }
pw=$(openssl rand -hex 16)
apw=$(openssl rand -hex 16)
kspw=$(openssl rand -hex 16)
export ARTEMIS_ADMIN_PASSWORD=$apw ARTEMIS_KS_PASSWORD=$kspw
trap 'dc down -v > /dev/null 2>&1; evidence_save "$pw" "$apw" "$kspw"; rm -rf "$work"' EXIT

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
# Each broker's etc-override: its JMX roles, its users (admin
# of role amq; monitor of role view, which may only read) and its roles.
for n in art233 art240 art244; do
    d=$work/etc/$n
    mkdir -p "$d"
    cp "$bk_dir/workloads/artemis/management.xml" "$d/"
    printf 'admin = %s\nmonitor = %s\n' "$apw" "$pw" > "$d/artemis-users.properties"
    printf 'amq = admin\nview = monitor\n' > "$d/artemis-roles.properties"
    cp "$bk_dir/workloads/artemis/broker.properties" "$d/"
    chmod 755 "$d" && chmod 644 "$d"/*
done

evidence_start pack-artemis "$bk_dir/$file" "$0" "$@"
pack=$work/pack
mkdir -p "$pack" && cp "$bk_repo/packs/artemis/pack.config" "$bk_repo/packs/artemis/linux"/* "$pack/" || die 'cannot copy the pack'
JAVA_HOME=${VIGIL_IT_ARTEMIS_JDK:-${JAVA_HOME-}} bash "$bk_repo/tools/release/client-jar.sh" "$pack" > "$work/jars.log" 2>&1 ||
    { cat "$work/jars.log"; die 'cannot build the pack'"'"'s jar'; }
sed 's/^client-jar: [^ ]*\/\(_[a-z]*\.jar\)/jar      \1/' "$work/jars.log"
printf 'java     %s\n' "$(java -version 2>&1 | head -n 1)"
[ -z "${VIGIL_IT_ARTEMIS_JRE-}" ] || printf 'jre      %s (%s)\n' "$("$VIGIL_IT_ARTEMIS_JRE/bin/java" -version 2>&1 | head -n 1)" "$VIGIL_IT_ARTEMIS_JRE"

dc up -d > "$work/up.log" 2>&1 || { cat "$work/up.log"; die 'the brokers would not start'; }
for _ in $(seq 1 60); do
    up=0
    for s in art233 art240 art244; do dc logs "$s" 2> /dev/null | grep -q 'AMQ221007' && up=$((up + 1)); done
    [ "$up" -eq 3 ] && break
    sleep 3
done
# Their logs, without the line 2.33 prints with the admin's password.
[ "$up" -eq 3 ] || { dc logs --tail 30 | grep -v CREATE_ARGUMENTS; die "only $up of 3 brokers started"; }
printf 'brokers  %s\n' "$(dc ps --format '{{.Service}} {{.Image}}' | sort | tr '\n' ';' | sed 's/;$//; s/;/; /g')"

say() { printf '\n# %s\n' "$*"; }
pass=0 fail=0
check() {
    if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; else fail=$((fail + 1)); printf '  FAIL  %s: expected [%s] actual [%s]\n' "$1" "$2" "$3"; fi
}
val() { grep -E "^metric $2 [^ ]+ .*$3" "$work/$1.out" | head -n 1 | awk '{ print $3 }'; }
least() { awk -v v="$(val "$1" "$2" "$3")" -v a="$4" 'BEGIN { print (v ~ /^[0-9.]+$/ && v + 0 >= a) ? "yes" : "no [" v "]" }'; }
# Artemis's own tools, in the broker's container, as admin, never waiting for ever.
art() { local s=$1 t=$2 p=$3; shift 3; dc exec -T "$s" timeout "$t" ./bin/artemis "$@" --url tcp://localhost:61616 --user admin --password "$p" > /dev/null 2>&1; }

say "Trouble, on each broker."
for s in art233 art240 art244; do
    art "$s" 180 "$apw" producer --destination queue://orders --message-count 3000 --message-size 2048
    art "$s" 60 "$apw" producer --destination queue://invoices --message-count 300
    art "$s" 60 "$apw" producer --destination queue://refunds --message-count 30
    art "$s" 60 "$apw" producer --destination queue://late --message-count 100 --msgttl 1000
    art "$s" 60 "$apw" producer --destination topic://nowhere --message-count 50
    # An address of 1 MB that blocks: its producer is held until the timeout.
    art "$s" 25 "$apw" producer --destination queue://blocked --message-count 2000 --message-size 10240
    # Logins refused.
    for i in 1 2 3; do art "$s" 30 not-the-password producer --destination queue://refunds --message-count 1; done
    # A slow consumer, kept connected: messages being delivered to it.
    dc exec -T -d "$s" timeout 600 ./bin/artemis consumer --url tcp://localhost:61616 --user admin --password "$apw" \
        --destination queue://orders --message-count 5 --sleep 120000 > /dev/null 2>&1
done
printf 'sent     on each: 3000 messages of 2 KB to an address of 1 MB that pages, 300 and 30 more, 100 that expire, 50 to an address no queue reads, an address that blocks, 3 logins refused, a slow consumer\n'
sleep 20

targets='art233: jmxs=localhost:19331; art240: jmxs=localhost:19332; art244: jmxs=localhost:19333'
export ARTEMIS_JMX=$targets ARTEMIS_JMX_USER=monitor ARTEMIS_JMX_PASSWORD=$pw ARTEMIS_CACERT=$tls/ca.crt
say "Every job, as the pack's scripts print it, as monitor (a role that may only read)."
jobs=$(sed -n 's/^\[job\.\(.*\)\]$/\1/p' "$pack/pack.config")
for j in $jobs; do
    printf '\n$ bash packs/artemis/%s.sh\n' "$j"
    bash "$pack/$j.sh" > "$work/$j.out" 2> "$work/$j.err"
    printf 'exit %s\n' "$?" >> "$work/$j.err"
    cat "$work/$j.out"
    grep -v '^exit 0$' "$work/$j.err"
done

say "What they read."
for j in $jobs; do check "artemis: $j runs" 'exit 0' "$(tail -n 1 "$work/$j.err")"; done
for t in art233:2.33 art240:2.40 art244:2.44; do
    n=${t%%:*} v=${t#*:}
    check "$n: answers over TLS, as a user that may only read" 1 "$(val status jmx_up "broker=$n ")"
    check "$n: its version, $v" yes "$(grep -qE "^metric version 1 broker=$n .* version=${v//./\\.}\.[0-9]+" "$work/status.out" && echo yes || echo no)"
    check "$n: started" 1 "$(val status started "broker=$n ")"
    check "$n: active" 1 "$(val status active "broker=$n ")"
    check "$n: not a backup" 0 "$(val status backup "broker=$n ")"
    check "$n: its acceptor" 1 "$(val status acceptor_up "broker=$n .*name=artemis")"
    check "$n: global-max-size" 33554432 "$(val broker global_max_bytes "broker=$n ")"
    check "$n: messages waiting" yes "$(least broker messages "broker=$n " 3330)"
    check "$n: logins refused" yes "$(least broker login_failed_count "broker=$n " 3)"
    check "$n: the largest address first" orders "$(grep -E "^metric size_bytes [^ ]+ broker=$n " "$work/addresses.out" | head -n 1 | sed 's/.*address=//')"
    check "$n: paging" 1 "$(val addresses paging "broker=$n .*address=orders\$")"
    check "$n: pages on disk" yes "$(least addresses pages "broker=$n .*address=orders\$" 1)"
    check "$n: the address that blocks, full" yes "$(least addresses limit_pct "broker=$n .*address=blocked\$" 90)"
    check "$n: messages routed nowhere" yes "$(least addresses unrouted_count "broker=$n .*address=nowhere\$" 50)"
    check "$n: the deepest queue first" orders "$(grep -E "^metric messages [^ ]+ broker=$n " "$work/queues.out" | head -n 1 | sed 's/.*queue=//')"
    check "$n: its oldest message's age" yes "$(least queues oldest_seconds "broker=$n .*queue=orders\$" 5)"
    check "$n: messages being delivered" yes "$(least queues delivering "broker=$n .*queue=orders\$" 1)"
    check "$n: to its consumer" 1 "$(val queues consumers "broker=$n .*queue=orders\$")"
    check "$n: messages expired" yes "$(least queues expired_count "broker=$n .*queue=late\$" 100)"
    check "$n: into the expiry queue" yes "$(least dlq expired "broker=$n .*queue=ExpiryQueue\$" 100)"
    check "$n: its dead letter queue, read" 0 "$(val dlq dead "broker=$n .*queue=DLQ\$")"
done

say "The pack through Vigil."
export VIGIL_IT_PROBE_PACK=artemis VIGIL_IT_PROBE_PACK_DIR=$pack VIGIL_IT_PROBE_TARGETS=$targets VIGIL_IT_PROBE_USER=monitor \
    VIGIL_IT_PROBE_PASSWORD=$pw VIGIL_IT_PROBE_CACERT=$tls/ca.crt VIGIL_IT_PROBE_EXPECT=artemis_queue_messages
unset ARTEMIS_JMX ARTEMIS_JMX_USER ARTEMIS_CACERT
ARTEMIS_JMX_PASSWORD='' bash "$bk_repo/tests/integration/service-packs.sh"
rc=$?
export ARTEMIS_JMX=$targets ARTEMIS_JMX_USER=monitor ARTEMIS_CACERT=$tls/ca.crt

say "The jar: refused when changed, and on a JRE."
cp -R "$pack" "$work/bad" && printf 'x' | dd of="$work/bad/_probe.jar" bs=1 seek=100 conv=notrunc 2> /dev/null
out=$(bash "$work/bad/status.sh" 2>&1)
check 'artemis: a probe changed by one byte is not run' 1 "$?"
printf '        %s\n' "$out"
if [ -n "${VIGIL_IT_ARTEMIS_JRE-}" ]; then
    check 'artemis: the JRE has no compiler' no "$([ -x "$VIGIL_IT_ARTEMIS_JRE/bin/javac" ] && echo yes || echo no)"
    bad=''
    for j in $jobs; do JAVA_HOME=$VIGIL_IT_ARTEMIS_JRE bash "$pack/$j.sh" > "$work/jre-$j.out" 2>&1 || bad="$bad $j"; done
    check 'artemis: every job runs on the JRE' '' "$bad"
    check 'artemis: and reads the same brokers' "$(grep -c '^metric jmx_up 1 ' "$work/status.out")" "$(grep -c '^metric jmx_up 1 ' "$work/jre-status.out")"
fi
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || rc=1

if [ -n "${VIGIL_IT_ARTEMIS_HOLD-}" ]; then
    hd=$VIGIL_IT_ARTEMIS_HOLD.d
    rm -rf "$hd" && (umask 077 && mkdir -p "$hd" && printf '%s' "$pw" > "$hd/pw") && cp "$tls/ca.crt" "$hd/ca.crt"
    : > "$VIGIL_IT_ARTEMIS_HOLD"
    say "Kept up for other machines' tests until $VIGIL_IT_ARTEMIS_HOLD is deleted."
    while [ -e "$VIGIL_IT_ARTEMIS_HOLD" ]; do sleep 5; done
    rm -rf "$hd"
fi
exit $rc
