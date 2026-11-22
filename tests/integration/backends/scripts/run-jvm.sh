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
# run-jvm.sh - the jvm pack against real JVMs with trouble on purpose, with
# its evidence kept like the other runs'.
#
#   scripts/run-jvm.sh
#
# It makes a TLS certificate from a CA of its own and a JMX password of the
# run's own, starts compose.jvm.yaml's JVMs (Java 8 to 25, each with a
# collector and troubles of its own, one crashing on purpose), and two JVMs
# on this machine as this account (one with JMX, one without). Then it runs
# tests/integration/service-packs.sh with them, shows what each of the
# pack's jobs reports, and what a JVM run as root shows to root (a container
# that sees this machine's processes, as Vigil running as root would). The
# JVMs are taken down at the end.
#
# The pack's client runs with this machine's java (JDK 11 or later).
#
# VIGIL_IT_JVM_JRE=<folder>: a JRE (11 or later, no compiler) to run every
# job on as well, from the client compiled as a packs release compiles it.
#
# VIGIL_IT_JVM_HOLD=<file>: at the end, the JVMs are kept up, with the JMX
# password and the CA in <file>.d/ (this account's only), for the tests of
# other machines (macOS, Windows), until <file> is deleted.

set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/common.sh"

command -v java > /dev/null 2>&1 || die 'java not found: the pack runs its client with a JDK 11 or later'
file=compose.jvm.yaml
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-jvm-it.XXXXXX") || exit 1
root=$work/none
dumps=$work/dumps
mkdir -p "$dumps"
export JVM_UID JVM_GID JVM_DUMPS_DIR=$dumps JVM_TLS_DIR=$work/tls JVM_PASSWD=$work/passwd
JVM_UID=$(id -u) JVM_GID=$(id -g)
# The containers' accounts: root, and this one by its name. A JVM whose
# account has no name keeps no counters, where a real one would.
printf 'root:x:0:0:root:/root:/bin/sh\n%s:x:%s:%s::/tmp:/bin/sh\n' "$(id -un)" "$JVM_UID" "$JVM_GID" > "$JVM_PASSWD"
chmod 644 "$JVM_PASSWD"
dc() { docker compose -p vigil-jvm --project-directory "$bk_dir" -f "$bk_dir/$file" "$@"; }
# The JMX password and the keystore's: this run's own.
pw=$(openssl rand -hex 16)
kspw=$(openssl rand -hex 16)
export JVM_JMX_PASSWORD=$pw JVM_KS_PASSWORD=$kspw
hostpids=''
trap 'for p in $hostpids; do kill "$p" 2> /dev/null; done; dc down -v > /dev/null 2>&1; evidence_save "$pw" "$kspw"; rm -rf "$work"' EXIT

# The JVMs' certificate, from a CA of this run's own: the names the pack
# connects by, localhost and 127.0.0.1. Java reads it as a PKCS#12 keystore.
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

evidence_start pack-jvm "$bk_dir/$file" "$0" "$@"
printf 'java     %s\n' "$(java -version 2>&1 | head -n 1)"
[ -z "${VIGIL_IT_JVM_JRE-}" ] || printf 'jre      %s (%s)\n' "$("$VIGIL_IT_JVM_JRE/bin/java" -version 2>&1 | head -n 1)" "$VIGIL_IT_JVM_JRE"
say() { printf '\n# %s\n' "$*"; }

dc up -d > "$work/up.log" 2>&1 || { cat "$work/up.log"; die 'the JVMs would not start'; }

# Two JVMs on this machine, as this account: one with JMX (password and
# TLS), one without. Each is told apart by an option of its own. JMX's
# password file first: it is read as the JVM starts.
(umask 077 && printf 'monitor %s\noperator %s\n' "$pw" "$pw" > "$work/jmx.password" && printf 'monitor readonly\noperator readwrite\n' > "$work/jmx.access")
(cd "$work" && exec java -Dvigil.it=hostjmx -Xmx128m -XX:+UseG1GC \
    -Dcom.sun.management.jmxremote.port=19190 -Dcom.sun.management.jmxremote.rmi.port=19190 \
    -Djava.rmi.server.hostname=localhost -Dcom.sun.management.jmxremote.authenticate=true \
    -Dcom.sun.management.jmxremote.password.file="$work/jmx.password" -Dcom.sun.management.jmxremote.access.file="$work/jmx.access" \
    -Dcom.sun.management.jmxremote.ssl=true -Dcom.sun.management.jmxremote.registry.ssl=true \
    -Djavax.net.ssl.keyStore="$tls/server.p12" -Djavax.net.ssl.keyStoreType=PKCS12 -Djavax.net.ssl.keyStorePassword="$kspw" \
    "$bk_dir/workloads/jvm/Trouble.java" busy leak deadlock > "$work/hostjmx.log" 2>&1) &
hostpids="$hostpids $!"
(cd "$work" && exec java -Dvigil.it=hostplain -Xmx128m -XX:+UseSerialGC "$bk_dir/workloads/jvm/Trouble.java" busy leak threadleak > "$work/hostplain.log" 2>&1) &
hostpids="$hostpids $!"

# Every JMX port answering, and the crasher crashed.
for _ in $(seq 1 60); do
    up=0
    for p in 19181 19182 19183 19184 19185 19190; do (exec 3<> "/dev/tcp/127.0.0.1/$p") 2> /dev/null && up=$((up + 1)); done
    [ "$up" -eq 6 ] && ls "$dumps"/hs_err_pid*.log > /dev/null 2>&1 && break
    sleep 3
done
[ "$up" -eq 6 ] || { dc logs --tail 20; die "only $up of 6 JMX ports answer"; }
ls "$dumps"/hs_err_pid*.log > /dev/null 2>&1 || die 'the crasher did not crash'
# A while of trouble: leaks, a heap dump, threads leaked.
sleep 60
printf 'jvms     %s\n' "$(dc ps --format '{{.Service}} {{.Image}}' | sort | tr '\n' ';' | sed 's/;$//; s/;/; /g')"

targets="j8: main=-XX:+UseParallelGC, jmx=localhost:19181, gclog=$dumps/j8-gc.log;"
targets="$targets j11: main=-XX:NativeMemoryTracking=summary, jmxs=localhost:19182;"
targets="$targets j17: main=-XX:+UseZGC, jmxs=localhost:19183, gclog=$dumps/j17-gc.log;"
targets="$targets j21: main=-XX:+HeapDumpOnOutOfMemoryError, jmxs=localhost:19184, gclog=$dumps/j21-gc.log;"
targets="$targets j25: main=-XX:+UseShenandoahGC, jmxs=localhost:19185;"
targets="$targets nojmx: main=-Dvigil.it=nojmx;"
targets="$targets host: main=-Dvigil.it=hostjmx, jmxs=localhost:19190;"
targets="$targets plain: main=-Dvigil.it=hostplain"

say "The pack through Vigil."
export VIGIL_IT_JVM_TARGETS=$targets VIGIL_IT_JVM_PASSWORD=$pw VIGIL_IT_JVM_CACERT=$tls/ca.crt VIGIL_IT_JVM_DUMPS=$dumps
bash "$bk_repo/tests/integration/service-packs.sh"
rc=$?

# Each job, as the pack's scripts print it, the password in their
# environment as a secret line would put it.
scripts=$bk_repo/packs/jvm/linux
[ "$(uname -s)" = Darwin ] && scripts=$bk_repo/packs/jvm/macos
export JVM_TARGETS=$targets JVM_JMX_USER=operator JVM_JMX_PASSWORD=$pw JVM_CACERT=$tls/ca.crt JVM_DUMP_DIRS=$dumps \
    JVM_MBEANS='java.lang:type=Threading/ThreadCount; java.lang:type=Memory/HeapMemoryUsage.used'
say "Every job."
for j in $(sed -n 's/^\[job\.\(.*\)\]$/\1/p' "$bk_repo/packs/jvm/pack.config"); do
    printf '\n$ bash packs/jvm/%s.sh\n' "$j"
    bash "$scripts/$j.sh" 2>&1 | head -n 120
done

say "As root: a container that sees this machine's processes, as Vigil running as root would."
unset JVM_TARGETS
docker run --rm --pid=host --cap-add SYS_PTRACE --user 0:0 -v "$scripts:/pack:ro,z" eclipse-temurin:21-jdk \
    sh -c 'for j in jvm_discovery jvm_heap; do echo "\$ java /pack/_client.java $j"; java -XX:-UsePerfData -XX:+UseSerialGC /pack/_client.java $j; done' 2>&1

if [ -n "${VIGIL_IT_JVM_HOLD-}" ]; then
    hd=$VIGIL_IT_JVM_HOLD.d
    rm -rf "$hd" && (umask 077 && mkdir -p "$hd" && printf '%s' "$pw" > "$hd/pw") && cp "$tls/ca.crt" "$hd/ca.crt"
    : > "$VIGIL_IT_JVM_HOLD"
    say "Kept up for other machines' tests until $VIGIL_IT_JVM_HOLD is deleted."
    while [ -e "$VIGIL_IT_JVM_HOLD" ]; do sleep 5; done
    rm -rf "$hd"
fi
exit $rc
