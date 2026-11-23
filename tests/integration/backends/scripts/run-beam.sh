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
# run-beam.sh - the beam pack against real Erlang nodes with trouble on
# purpose, with its evidence kept like the other runs'.
#
#   scripts/run-beam.sh
#
# It makes a cookie of the run's own and starts compose.beam.yaml's nodes,
# Erlang/OTP 25, 26, 27 and 28, each running workloads/beam/trouble.erl (a
# mailbox nobody reads, a cache that never evicts, atoms and processes
# leaking, a process holding binaries, a busy loop), and RabbitMQ 4.2 for
# its Prometheus page. Two VMs die on purpose first, as the run's own
# account, for their crash dumps: one of atoms, one of memory. Every job of
# the pack is run and what it reads is checked, with the escript of
# Erlang/OTP 28 and then of 25 (each image's own, in a container on this
# machine's network: the cookie goes in by name, never on a command line);
# then tests/integration/service-packs.sh runs the pack through Vigil. The
# nodes are taken down at the end.

set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/common.sh"

command -v docker > /dev/null 2>&1 || die 'docker not found: the nodes run in containers'
file=compose.beam.yaml
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-beam-it.XXXXXX") || exit 1
root=$work/none
export BEAM_WORK=$work/w
dc() { docker compose -p vigil-beam --project-directory "$bk_dir" -f "$bk_dir/$file" "$@"; }
cookie=$(openssl rand -hex 16)
trap 'dc down -v > /dev/null 2>&1; evidence_save "$cookie"; rm -rf "$work"' EXIT
evidence_start pack-beam "$bk_dir/$file" "$0" "$@"
pack=$bk_repo/packs/beam/linux

# The run's own: the cookie (twice: a file for -setcookie, and a home's
# .erlang.cookie, as the nodes take them), trouble.beam, a folder of dumps.
mkdir -p "$BEAM_WORK/home" "$work/dumps"
(umask 077 && printf '%s' "$cookie" > "$BEAM_WORK/cookie" && printf '%s' "$cookie" > "$BEAM_WORK/home/.erlang.cookie")
chmod 400 "$BEAM_WORK/home/.erlang.cookie"
chmod 644 "$BEAM_WORK/cookie"
chmod 755 "$BEAM_WORK" "$BEAM_WORK/home"
cp "$bk_dir/workloads/beam/trouble.erl" "$work/"
as_me=(--user "$(id -u):$(id -g)" -e HOME=/tmp)
docker run --rm "${as_me[@]}" -v "$work:/r:z" -w /r erlang:25 erlc -o /r/w trouble.erl > /dev/null || die 'cannot compile trouble.erl'

say() { printf '\n# %s\n' "$*"; }
pass=0 fail=0
check() {
    if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; else fail=$((fail + 1)); printf '  FAIL  %s: expected [%s] actual [%s]\n' "$1" "$2" "$3"; fi
}
val() { grep -E "^metric $2 [^ ]+ .*$3" "$work/$1.out" | head -n 1 | awk '{ print $3 }'; }
least() { awk -v v="$(val "$1" "$2" "$3")" -v a="$4" 'BEGIN { print (v ~ /^[0-9.]+$/ && v + 0 >= a) ? "yes" : "no [" v "]" }'; }

say "Two VMs die, as this account, for their crash dumps."
docker run --rm "${as_me[@]}" -v "$work:/r:z" -w /r -e ERL_CRASH_DUMP=/r/dumps/atoms.dump erlang:27 \
    erl +t 20000 -noshell -name dead27@127.0.0.1 -setcookie x -pa /r/w -eval 'trouble:crash(atoms)' 2>&1 | tail -n 2
docker run --rm "${as_me[@]}" -v "$work:/r:z" -w /r -e ERL_CRASH_DUMP=/r/dumps/memory.dump erlang:28 \
    sh -c "ulimit -v 2500000; exec erl +MMscs 0 -noshell -name dead28@127.0.0.1 -setcookie x -pa /r/w -eval 'trouble:crash(memory)'" 2>&1 | tail -n 2
ls -l "$work/dumps" | sed 's/^/         /'

dc up -d > /dev/null 2>&1 || { dc logs --tail 20; die 'the nodes would not start'; }
for _ in $(seq 1 60); do curl -sf -o /dev/null http://127.0.0.1:15692/metrics && break; sleep 3; done
printf 'nodes    %s\n' "$(dc ps --format '{{.Service}} {{.Image}}' | sort | tr '\n' ';' | sed 's/;$//; s/;/; /g')"
# A minute of trouble: past 1,000 messages in the mailbox nobody reads.
sleep 60

# escript, as an image has it, on this machine's network: the settings and
# the cookie go in by name (-e NAME), never by value.
mkdir -p "$work/erlang28/bin" "$work/erlang25/bin"
for v in 28 25; do
    cat > "$work/erlang$v/bin/escript" << EOF
#!/usr/bin/env bash
exec docker run --rm -i --network host -e BEAM_DIST -e BEAM_COOKIE -e HOME -v "\$HOME:\$HOME:z" -v "\$(dirname "\$1"):\$(dirname "\$1"):ro,z" erlang:$v escript "\$@"
EOF
    chmod 755 "$work/erlang$v/bin/escript"
done

dist='t25=t25@127.0.0.1; t26=t26@127.0.0.1; t27=t27@127.0.0.1; t28=t28@127.0.0.1'
prom='rabbit=http://127.0.0.1:15692/metrics'
export BEAM_DIST=$dist BEAM_PROMETHEUS=$prom BEAM_COOKIE=$cookie BEAM_CRASH_DUMPS=$work/dumps BEAM_ERLANG=$work/erlang28
say "Every job, as the pack's scripts print it, with Erlang/OTP 28's escript."
jobs=$(sed -n 's/^\[job\.\(.*\)\]$/\1/p' "$bk_repo/packs/beam/pack.config")
for j in $jobs; do
    printf '\n$ bash packs/beam/linux/%s.sh\n' "$j"
    bash "$pack/$j.sh" > "$work/$j.out" 2> "$work/$j.err"
    printf 'exit %s\n' "$?" >> "$work/$j.err"
    cat "$work/$j.out"
    grep -v '^exit 0$' "$work/$j.err"
done

say "What they read."
for j in $jobs; do check "beam: $j runs" 'exit 0' "$(tail -n 1 "$work/$j.err")"; done
check 'process: the four nodes and RabbitMQ, at least' yes "$(least process beams '' 5)"
for v in 25 26 27 28; do
    n=t$v
    check "$n: seen by the OS, by its node name" 1 "$(val process running "node=$n@127.0.0.1 ")"
    want=1; [ "$v" -ge 27 ] && want=0
    check "$n: its cookie on its command line: $want" "$want" "$(val process cookie_on_command_line "node=$n@127.0.0.1\$")"
    check "$n: registered with epmd" 1 "$(val epmd node "name=$n port=195$v")"
    check "$n: answers with the cookie" 1 "$(val vm up "node=$n source=dist")"
    check "$n: Erlang/OTP $v" 1 "$(val vm version "node=$n source=dist otp=$v ")"
    check "$n: its atoms, rising" yes "$(least vm atoms "node=$n source=dist" 10500)"
    check "$n: its processes, leaking" yes "$(least vm processes "node=$n source=dist" 300)"
    check "$n: the mailbox nobody reads, over 1,000" yes "$(least processes mailbox "node=$n source=dist process=slow_consumer" 1000)"
    check "$n: counted among those over 1,000" 1 "$(val processes mailboxes_over_1000 "node=$n ")"
    check "$n: the busiest process: the busy loop" spinner "$(grep -E "^metric process_reductions_count [^ ]+ node=$n " "$work/processes.out" | head -n 1 | sed 's/.*process=//')"
    check "$n: the largest table: the cache that never evicts" 'leaky_cache owner=trouble:cache/1' "$(grep -E "^metric table_memory_bytes [^ ]+ node=$n " "$work/tables.out" | head -n 1 | sed 's/.*table=//; s/ owner=/ owner=/')"
    check "$n: its kernel application" 1 "$(val apps app "node=$n source=dist app=kernel ")"
    check "$n: alone, not in a cluster" 0 "$(val dist peers "node=$n ")"
done
check 'rabbit: answers on Prometheus' 1 "$(val vm up 'node=rabbit source=prometheus')"
check 'rabbit: its atom limit, RabbitMQ'"'"'s 5,000,000' 5000000 "$(val vm atom_limit 'node=rabbit source=prometheus')"
check 'rabbit: seen by the OS, by its -s module' 1 "$(val process running 'node=rabbit ')"
check 'crash dumps: both found' 2 "$(val crashdumps dumps '')"
check 'crash dumps: the one out of atoms, and why' yes "$(grep -q '^metric dump 1 file=.*/atoms.dump node=dead27@127.0.0.1 slogan=no_more_index_entries_in_atom_tab_(max=20000)$' "$work/crashdumps.out" && echo yes || echo no)"
check 'crash dumps: the one out of memory, and why' yes "$(grep -q '^metric dump 1 file=.*/memory.dump node=dead28@127.0.0.1 slogan=eheap_alloc:_Cannot_allocate_[0-9]*_bytes_of_memory_(of_type_heap)' "$work/crashdumps.out" && echo yes || echo no)"

say "The same, with Erlang/OTP 25's escript."
bad=''
for j in vm processes tables dist apps; do BEAM_ERLANG=$work/erlang25 bash "$pack/$j.sh" > "$work/otp25-$j.out" 2>&1 || bad="$bad $j"; done
check 'beam: every cookie job runs with Erlang/OTP 25' '' "$bad"
check 'beam: and reads every node' 4 "$(grep -c '^metric up 1 node=t2[5-8] source=dist$' "$work/otp25-vm.out")"

say "A wrong cookie, a node that is down, an epmd that is not there."
BEAM_COOKIE=not-the-cookie bash "$pack/vm.sh" > "$work/wrong.out" 2>&1
check 'beam: a wrong cookie fails the run' 1 "$?"
check 'beam: and says so' yes "$(grep -q 'is not its cookie, or' "$work/wrong.out" && echo yes || echo no)"
BEAM_DIST='gone=gone@127.0.0.1' bash "$pack/dist.sh" > "$work/gone.out" 2>&1
check 'beam: a node that is down still runs' 0 "$?"
check 'beam: and reads as up 0' yes "$(grep -q '^metric up 0 node=gone source=dist$' "$work/gone.out" && echo yes || echo no)"
BEAM_EPMD='127.0.0.1:4999' bash "$pack/epmd.sh" > "$work/noepmd.out" 2>&1
check 'beam: an epmd that is not there reads as epmd_up 0' yes "$(grep -q '^metric epmd_up 0 host=127.0.0.1:4999$' "$work/noepmd.out" && echo yes || echo no)"

say "The pack through Vigil."
export VIGIL_IT_BEAM_DIST=$dist VIGIL_IT_BEAM_COOKIE=$cookie VIGIL_IT_BEAM_ERLANG=$work/erlang28 \
    VIGIL_IT_BEAM_PROMETHEUS=$prom VIGIL_IT_BEAM_DUMPS=$work/dumps VIGIL_IT_BEAM_TROUBLE=t28
unset BEAM_DIST BEAM_PROMETHEUS BEAM_COOKIE BEAM_CRASH_DUMPS BEAM_ERLANG
bash "$bk_repo/tests/integration/service-packs.sh"
rc=$?
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && [ "$rc" -eq 0 ]
