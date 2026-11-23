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
# probe-test.sh - the probe's tables, against MBeans made for it
# (Fixture.java, plain JMX on this machine only): each word of a row, named
# targets, and the tables it refuses. The packs' own runs test it against
# real servers; this tests what they may not show, such as the worst of 150
# queues, every time the probe changes (CI's pack java job).
#
#   tools/probe/test/probe-test.sh
#
# Needs a JDK 11 or later (JAVA_HOME's, or the PATH's).
# Exit code: 0 every check passed; 1 otherwise.

set -u
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
bin=
[ -n "${JAVA_HOME-}" ] && [ -x "$JAVA_HOME/bin/javac" ] && bin=$JAVA_HOME/bin/
command -v "${bin}javac" > /dev/null 2>&1 || { echo 'probe-test: javac not found: a JDK 11 or later, in JAVA_HOME or on the PATH' >&2; exit 1; }
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-probe-test.XXXXXX") || exit 1
fixture=
trap '[ -n "$fixture" ] && kill "$fixture" 2> /dev/null; rm -rf "$work"' EXIT

passed=0 failed=0
pass() { passed=$((passed + 1)); printf '  PASS  %s\n' "$1"; }
fail() { failed=$((failed + 1)); printf '  FAIL  %s\n' "$1"; [ -n "${2-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
# has <name> <output> <line>: the output has that line, whole.
has() { if printf '%s\n' "$2" | grep -qxF -- "$3"; then pass "$1"; else fail "$1" "$2"; fi; }
# lacks <name> <output> <regex>: no line of the output matches.
lacks() { if printf '%s\n' "$2" | grep -qE -- "$3"; then fail "$1" "$2"; else pass "$1"; fi; }

# The probe, as a pack carries it; the fixture, from its source.
"${bin}javac" --release 11 -nowarn -d "$work/probe" "$repo/tools/probe/_probe.java" || { echo 'probe-test: the probe does not compile' >&2; exit 1; }
"${bin}java" "$here/Fixture.java" > "$work/fixture.log" 2>&1 &
fixture=$!
port=
for _ in $(seq 1 60); do
    port=$(sed -n 's/^ready \([0-9]*\)$/\1/p' "$work/fixture.log")
    [ -n "$port" ] && break
    kill -0 "$fixture" 2> /dev/null || break
    sleep 1
done
[ -n "$port" ] || { cat "$work/fixture.log"; echo 'probe-test: the fixture did not start' >&2; exit 1; }
printf 'probe-test: %s; the fixture at localhost:%s\n' "$("${bin}java" -version 2>&1 | head -n 1)" "$port"

cat > "$work/t.tables" << 'EOF'
targets   PT_JMX
user      PT_USER
password  PT_PASSWORD
cacert    PT_CACERT
name      server

[worst]
size      fixture:type=Queue,*  Size      name  top  -name=ActiveMQ.Advisory.*
enqueued  fixture:type=Queue,*  Enqueued  name  -name=ActiveMQ.Advisory.*

[byname]
size      fixture:type=Queue,*  Size      name

[apps]
started   fixture:type=App,*  stateName  name  =STARTED
running   fixture:type=App,*  stateName  name  =started|STOPPED
available fixture:type=App,*  available  name
kept      fixture:type=App,*  stateName  name  =STARTED  -name=//localhost/b*

[pool]
busy      fixture:type=Pool,*  busy  name

[memory]
used      fixture:type=Memory  Usage.used
ok        fixture:type=Memory  Usage.state  =OK
EOF
probe() { PT_JMX=$1 "${bin}java" -cp "$work/probe" Probe "$work/t.tables" "$2" 2>&1; }
t="web1: jmx=localhost:$port"

out=$(probe "$t" worst)
has 'top: the worst queue first' "$(printf '%s\n' "$out" | sed -n 2p)" "metric size 9999 server=web1 jmx=localhost:$port name=q007"
has 'top: the 100th worst shown' "$out" "metric size 50 server=web1 jmx=localhost:$port name=q$(printf '%03d' 50)"
lacks 'top: and the 101st not' "$out" '^metric size 49 '
has 'top: the rest counted' "$out" "metric size_not_shown 50 server=web1 jmx=localhost:$port"
lacks 'excluded: none of the noise' "$out" 'Advisory'
has 'top: a row of the same MBeans follows its order' "$(printf '%s\n' "$out" | grep '^metric enqueued ' | head -n 1)" "metric enqueued 70 server=web1 jmx=localhost:$port name=q007"
has 'top: and counts the same' "$out" "metric enqueued_not_shown 50 server=web1 jmx=localhost:$port"

out=$(probe "$t" byname)
has 'by name, as before: the first' "$(printf '%s\n' "$out" | sed -n 2p)" "metric size 50000 server=web1 jmx=localhost:$port name=ActiveMQ.Advisory.0"
lacks 'by name: past the first 100, none' "$out" 'name=q(09[7-9]|1[0-4][0-9])$'
has 'by name: the rest counted' "$out" "metric size_not_shown 53 server=web1 jmx=localhost:$port"

out=$(probe "$t" apps)
has 'a state: started' "$out" "metric started 1 server=web1 jmx=localhost:$port name=//localhost/shop"
has 'a state: failed is not' "$out" "metric started 0 server=web1 jmx=localhost:$port name=//localhost/broken"
has 'a state of several, case aside' "$out" "metric running 1 server=web1 jmx=localhost:$port name=//localhost/stopped"
has 'and not the others' "$out" "metric running 0 server=web1 jmx=localhost:$port name=//localhost/broken"
has 'a boolean, as before' "$out" "metric available 1 server=web1 jmx=localhost:$port name=//localhost/shop"
lacks 'excluded by a quoted name' "$out" '^metric kept .*broken'
has 'and the rest kept' "$out" "metric kept 0 server=web1 jmx=localhost:$port name=//localhost/stopped"

out=$(probe "$t" pool)
has 'a quoted name, as a tag without its quotes' "$out" "metric busy 5 server=web1 jmx=localhost:$port name=http-nio-8080"

out=$(probe "$t" memory)
has 'a composite key, as before' "$out" "metric used 10 server=web1 jmx=localhost:$port"
has 'a state in a composite key' "$out" "metric ok 1 server=web1 jmx=localhost:$port"

out=$(probe "web1: jmxs=localhost:1; jmx=localhost:$port" memory)
has 'a target named in the setting' "$out" "metric jmx_up 0 server=web1 jmx=localhost:1"
has 'and one named by its address' "$out" "metric jmx_up 1 server=localhost:$port jmx=localhost:$port"

# What it refuses, saying where.
refused() {
    printf 'targets PT_JMX\n\n[bad]\n%s\n' "$2" > "$work/bad.tables"
    out=$(PT_JMX="jmx=localhost:$port" "${bin}java" -cp "$work/probe" Probe "$work/bad.tables" bad 2>&1)
    rc=$?
    if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -qF -- "$3"; then pass "$1"; else fail "$1" "exit $rc: $out"; fi
}
refused 'sum and top together, refused' 'x fixture:type=Queue,* Size name sum top' 'line 4: sum or top, not both'
refused 'a word it does not know, refused' 'x fixture:type=Queue,* Size name ~odd' 'not a tag, +tag=value, -key=pattern, =STATE, *n, >=n, sum or top: ~odd'
out=$(PT_JMX='web1 jmx=localhost:1' "${bin}java" -cp "$work/probe" Probe "$work/t.tables" memory 2>&1)
if [ $? -eq 1 ] && printf '%s\n' "$out" | grep -qF 'with a name first or not (web1: jmxs=host:port)'; then pass 'a target it cannot read, refused'; else fail 'a target it cannot read, refused' "$out"; fi

printf '%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
