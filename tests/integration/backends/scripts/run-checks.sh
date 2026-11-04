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
# run-checks.sh - the delivery checks of section 5 beyond what run-vigil.sh
# shows, against one running target, on the Docker host: it stops and
# starts the target's containers.
#
#   scripts/start.sh prometheus
#   scripts/run-checks.sh prometheus
#
# One Vigil, with the target and a local file backend, runs a job every 5
# seconds that writes down its own run (a ledger outside Vigil), reports the
# second it ran as a metric, and prints it as a log line. Then, in turn:
#   - the target is stopped for 70 seconds, and started again
#   - the target is restarted
#   - Vigil's supervisor is stopped for 10 seconds, and started again
#   - the spool is cut to 1 MB, a job floods it, and the target is stopped
# The backend's own query interface is then asked what it holds, and each
# run in the ledger is looked for. Checks, numbered as in section 5:
#    4 job identifiers and labels   10 recovery from the spool
#    5 host metadata                11 a backend restart
#    6 timestamps preserved         12 duplicate delivery
#    7 authentication rejected      13 dropped telemetry reported
#    8 the backend unavailable      14 several destinations
#    9 retry and backoff            15 a healthy destination unaffected
#                                   16 a supervisor restart
# Needs curl and jq. Linux. Exit code: 0 when nothing failed.

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/common.sh"

[ "$#" -eq 1 ] || die 'usage: run-checks.sh <target>'
target=$1
endpoints "$target"
[ -z "$bk_why" ] || die "$target: not applicable to Vigil: $bk_why"
command -v jq > /dev/null 2>&1 || die 'run-checks.sh needs jq'
services=$(services_of "$target")
[ -n "$services" ] || die "no containers for $target"

# Where to ask: a Prometheus-style API for metrics, a Loki one for logs.
prom='' loki=''
case $target in
    prometheus | alloy) prom=http://127.0.0.1:9090/api/v1 ;;
    mimir | otel-collector) prom=http://127.0.0.1:9009/prometheus/api/v1 ;;
esac
case $target in loki | otel-collector | alloy) loki=http://127.0.0.1:3100/loki/api/v1 ;; esac

tag="ck$(date -u '+%Y%m%d%H%M%S')$$"
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-ck.XXXXXX") || exit 1
root=$work/root
ledger=$work/ledger
sup=''
pass=0 fail=0 skip=0
cleanup() {
    # The supervisor this script started, and nothing else.
    [ -n "$sup" ] && kill "$sup" 2> /dev/null
    end_workers
    # The target is left running, as start.sh left it.
    [ -n "${down-}" ] && start_target > /dev/null
    evidence_save "${VIGIL_SPLUNK_METRICS_TOKEN-}" "${VIGIL_SPLUNK_LOGS_TOKEN-}"
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 1' TERM INT HUP

mkdir -p "$root/scripts" "$root/config" && cp -R "$bk_repo/app" "$root/" || exit 1
: > "$ledger"
evidence_start "checks-$target" "$bk_dir/compose*.yaml" "$0" "$@"

result() {
    local word=$1
    shift
    case $word in
        PASS) pass=$((pass + 1)) ;;
        FAIL) fail=$((fail + 1)) ;;
        *) skip=$((skip + 1)) ;;
    esac
    printf '  %s  %s\n' "$word" "$*"
}
say() { printf '%s %s\n' "$(date -u '+%H:%M:%S')" "$*"; }
vigil() { bash "$root/app/vigil" --root "$root" "$@" < /dev/null; }
# Not through vigil(): a function run in the background is a subshell, and
# $! would be that subshell, so stopping it would leave the supervisor up.
start_sup() {
    bash "$root/app/vigil" --root "$root" supervise < /dev/null >> "$work/supervise.out" 2>&1 &
    sup=$!
}
stop_target() { compose --profile "$target" stop $services > /dev/null 2>&1; down=1; }
start_target() { bash "$here/start.sh" "$target" > "$work/start.out" 2>&1 && down=''; }

# The job: writes its run in the ledger, then reports it as a metric and a
# line. Its metric is bk_check.seq, whose value is the second it ran.
cat > "$root/scripts/check.sh" << 'EOF'
s=$(date +%s)
echo "$s" >> "$BK_LEDGER"
echo "metric seq $s run=$BK_RUN"
echo "line $BK_RUN $s"
EOF
# Many series in one run, to fill a small spool: 1000, the most Vigil takes
# from a run (14.3).
cat > "$root/scripts/flood.sh" << 'EOF'
i=0
while [ "$i" -lt 1000 ]; do echo "metric flood_$i 1 run=$BK_RUN"; i=$((i + 1)); done
EOF

config() {
    printf '[vigil]\ninstance = backend-check\n\n[scheduler]\ntick = 2s\n\n'
    printf '[runner.sh]\ncommand = /bin/bash\n\n[runners]\n.sh = sh\n\n'
    [ -n "${1-}" ] && printf '[spool]\nmax_mb = 1\n\n'
    if [ -n "$bk_metrics" ]; then
        printf '[backend.target]\ntype     = %s\nendpoint = %s\n\n' "${bk_metrics%% *}" "${bk_metrics#* }"
    fi
    # The second destination, healthy throughout.
    printf '[backend.local]\ntype = file\npath = metrics/local.prom\n\n'
    if [ -n "$bk_logs" ]; then
        printf '[log_forward]\ndestination = target\ninclude     = run, stdout, stderr\ncheck_every = 5s\n\n'
        printf '[log_destination.target]\ntype     = %s\nendpoint = %s\n\n' "${bk_logs%% *}" "${bk_logs#* }"
    fi
    printf '[job.bk_check]\nfile = scripts/check.sh\nrun_every = 5s\nenv = BK_RUN=%s\nenv = BK_LEDGER=%s\n\n' "$tag" "$ledger"
    # To the target only: the file backend merges about 430 events a second
    # (backlog 29), and would hold up the sender for the flood.
    [ -n "${1-}" ] && printf '[job.bk_flood]\nfile = scripts/flood.sh\nrun_every = 2s\nbackends = target\nenv = BK_RUN=%s\n' "$tag"
    return 0
}
config > "$root/config/vigil.config"

# PromQL $1 at time $2 (default now), as JSON.
pq() { curl -fsS -m 30 -G "$prom/query" --data-urlencode "query=$1" ${2:+--data-urlencode "time=$2"}; }
# Every stored sample of bk_check.seq for this run, as "<timestamp> <value>".
samples() { pq "bk_check_seq{run=\"$tag\"}[1h]" | jq -r '.data.result[0].values[]? | "\(.[0]) \(.[1])"'; }
# Every stored line for this run, as "<nanoseconds> <line>".
lines() {
    curl -fsS -m 30 -G "$loki/query_range" --data-urlencode "query={service_name=\"vigil\"} |= \"line $tag \"" \
        --data-urlencode "since=1h" --data-urlencode 'limit=5000' --data-urlencode 'direction=forward' |
        jq -r '.data.result[].values[] | "\(.[0]) \(.[1])"'
}
# The labels of the latest bk_check.seq sample, one "key=value" a line.
labels() { pq "last_over_time(bk_check_seq{run=\"$tag\"}[1h])" | jq -r '.data.result[0].metric | to_entries[] | "\(.key)=\(.value)"'; }
# The value of the first series in the local file backend whose line starts
# with $1 (its labels are sorted by key), or nothing.
local_value() { awk -v p="$1" 'index($0, p) == 1 { print $NF; exit }' "$root/metrics/local.prom" 2> /dev/null; }
# The ledger's runs from second $1 up to, not including, second $2.
ledger_between() { awk -v a="$1" -v b="$2" '$1 >= a && $1 < b' "$ledger"; }

say "$target, run $tag: services $services"
[ -n "$prom" ] || [ -z "$bk_metrics" ] || say "no query helper for $target's metrics yet: those checks are NOT RUN"
[ -n "$loki" ] || [ -z "$bk_logs" ] || say "no query helper for $target's logs yet: those checks are NOT RUN"
vigil precheck > "$work/precheck.out" 2>&1 || { cat "$work/precheck.out"; die 'precheck failed'; }
# Up at the start, whatever state it was left in.
start_target || { cat "$work/start.out"; die "$target did not start"; }

t_start=$(date +%s)
start_sup
say 'baseline: 40 seconds'
sleep 40

# 8, 9, 15: the target stopped.
say "stopping $target"
t_down=$(date +%s)
stop_target
fresh=yes
for _ in $(seq 1 14); do
    sleep 5
    # The file backend's copy keeps up: the job's latest run is there.
    v=$(local_value 'bk_check_seq{')
    [ -n "$v" ] && [ $(($(date +%s) - v)) -le 20 ] || fresh="no (latest $v at $(date +%s))"
done
fwd=$(sed -n 's/^failures = //p' "$root/state/logs/forwarder.state" 2> /dev/null)
queued=$(find "$root/spool/backends/target" -name '*.events' 2> /dev/null | wc -l)
say "starting $target"
t_up=$(date +%s)
start_target || say "$target did not come back: $(tail -1 "$work/start.out")"
say 'recovery: 40 seconds'
sleep 40

# 11: a restart.
say "restarting $target"
t_restart=$(date +%s)
compose --profile "$target" restart $services > /dev/null 2>&1
start_target
sleep 30

# 16: the supervisor stopped and started again.
say 'stopping the supervisor for 10 seconds'
t_sup=$(date +%s)
kill "$sup" 2> /dev/null
wait "$sup" 2> /dev/null
sleep 10
start_sup
sleep 30
t_main=$(date +%s)
say 'letting delivery catch up: 30 seconds'
sleep 30

# What the target holds for the runs before t_main.
want=$(ledger_between 0 "$t_main" | sort -n)
nwant=$(printf '%s\n' "$want" | grep -c .)
if [ -n "$prom" ]; then
    samples > "$work/samples.txt" 2> "$work/samples.err"
    labels > "$work/labels.txt" 2>&1
    got=$(awk '{ print $2 }' "$work/samples.txt" | sort -n | awk -v m="$t_main" '$1 < m')
fi
if [ -n "$loki" ]; then
    lines > "$work/lines.txt" 2> "$work/lines.err"
    gotl=$(awk '{ print $4 }' "$work/lines.txt" | sort -n | awk -v m="$t_main" '$1 < m')
fi
# Missing and duplicated seconds, as counts, from a list on stdin.
missing() { comm -23 <(printf '%s\n' "$want" | sort -u) <(sort -u) | grep -c .; }
dups() { sort | uniq -d | grep -c .; }

# 13: a spool too small for an outage. Only metrics go through the spool.
if [ -n "$bk_metrics" ]; then
    # The target first: while it is backing off, the flood only queues. The
    # bash sender encodes a large batch slowly (backlog 29), and a flood sent
    # to a live target would measure that instead.
    say 'the target stopped, the spool cut to 1 MB, and a flood job'
    stop_target
    config small > "$root/config/vigil.config.tmp" && mv -f "$root/config/vigil.config.tmp" "$root/config/vigil.config"
    i=0
    until [ -n "$(local_value 'vigil_spool_dropped_total{backend="target"')" ] || [ "$i" -ge 40 ]; do sleep 3; i=$((i + 1)); done
    dropped_local=$(grep -h '^vigil_spool_dropped_total{' "$root/metrics/local.prom" 2> /dev/null | grep 'backend="target"')
    config > "$root/config/vigil.config.tmp" && mv -f "$root/config/vigil.config.tmp" "$root/config/vigil.config"
    start_target
    say 'recovery: up to 3 minutes, for the count to reach the target'
    i=0
    while [ -n "$prom" ] && [ "$i" -lt 36 ]; do
        # Prometheus adds _total to a counter's name; Mimir, by default, does not.
        pq "{__name__=~\"vigil_spool_dropped(_total)?\",backend=\"target\",instance=\"backend-check\"}" > "$work/dropped.json" 2>&1
        jq -e '.data.result | length > 0' "$work/dropped.json" > /dev/null 2>&1 && break
        sleep 5
        i=$((i + 1))
    done
fi
kill "$sup" 2> /dev/null
wait "$sup" 2> /dev/null
sup=''

printf '\n%s, run %s: %s runs before %s\n' "$target" "$tag" "$nwant" "$(date -u -d "@$t_main" '+%H:%M:%SZ')"
printf '  outage %s to %s, restart %s, supervisor down %s to %s\n' \
    "$(date -u -d "@$t_down" +%T)" "$(date -u -d "@$t_up" +%T)" "$(date -u -d "@$t_restart" +%T)" \
    "$(date -u -d "@$t_sup" +%T)" "$(date -u -d "@$((t_sup + 10))" +%T)"

# 4, 5: what the backend kept of Vigil's tags, against the file backend's.
if [ -n "$prom" ]; then
    printf '  stored labels: %s\n' "$(tr '\n' ' ' < "$work/labels.txt")"
    sent=$(grep -h '^bk_check_seq{' "$root/metrics/local.prom" | head -n 1 | sed 's/^[^{]*{//; s/}.*//' | tr ',' '\n' | tr -d '"')
    printf '  sent labels:   %s\n' "$(printf '%s\n' "$sent" | tr '\n' ' ')"
    job=$(sed -n 's/^job=//p' "$work/labels.txt")
    if [ "$job" = bk_check ]; then
        result PASS '4 job identifiers and labels: job="bk_check" kept'
    elif grep -q '^__name__=bk_check_' "$work/labels.txt"; then
        result PASS "4 job identifiers and labels: the job is in the metric name (bk_check_seq); its job label became job=\"$job\""
    else
        result FAIL '4 job identifiers and labels: the job is in neither the name nor a label'
    fi
    lost=''
    for kv in $(printf '%s\n' "$sent" | grep -E '^(host|os|instance|run)='); do
        grep -qx "$kv" "$work/labels.txt" || lost="$lost $kv"
    done
    if [ -z "$lost" ]; then result PASS '5 host metadata: host, os and instance kept'; else result FAIL "5 host metadata: lost$lost"; fi
elif [ -n "$bk_metrics" ]; then
    result 'NOT RUN' "4, 5 labels: no query helper for $target"
fi
if [ -n "$loki" ]; then
    stream=$(curl -fsS -m 30 -G "$loki/query_range" --data-urlencode "query={service_name=\"vigil\"} |= \"line $tag \"" \
        --data-urlencode "since=1h" --data-urlencode 'limit=1' | jq -r '.data.result[0].stream | to_entries[] | "\(.key)=\(.value)"' | tr '\n' ' ')
    printf '  stored log labels: %s\n' "$stream"
    case " $stream " in
        *" job=bk_check "*) result PASS '4 logs: job="bk_check" kept as a label' ;;
        *) result FAIL "4 logs: no job=bk_check in $stream" ;;
    esac
    case " $stream " in
        *" host="*" os="* | *" os="*" host="*) result PASS '5 logs: host and os kept as labels' ;;
        *) result FAIL "5 logs: host or os missing from $stream" ;;
    esac
fi

# 6: a delayed sample keeps the time it was made, not the time it arrived.
if [ -n "$prom" ]; then
    off=$(awk '{ d = int($1) - $2; if (d < 0 || d > 10) bad++; if (d > max) max = d } END { printf "%d %d", bad, max }' "$work/samples.txt")
    late=$(awk -v a="$t_down" -v b="$t_up" '$2 >= a && $2 < b' "$work/samples.txt" | grep -c .)
    if [ "${off% *}" -eq 0 ] && [ "$late" -gt 0 ]; then
        result PASS "6 timestamps: every sample within ${off#* }s of its run, the $late delivered late after the outage too"
    else
        result FAIL "6 timestamps: ${off% *} samples more than 10s from their run (largest ${off#* }s); $late from the outage"
    fi
fi
if [ -n "$loki" ]; then
    off=$(awk '{ d = int($1 / 1000000000) - $4; if (d < 0 || d > 10) bad++; if (d > max) max = d } END { printf "%d %d", bad, max }' "$work/lines.txt")
    if [ "${off% *}" -eq 0 ] && [ -s "$work/lines.txt" ]; then
        result PASS "6 timestamps (logs): every line within ${off#* }s of its run"
    else
        result FAIL "6 timestamps (logs): ${off% *} lines more than 10s from their run (largest ${off#* }s)"
    fi
fi

result 'NOT APPLICABLE' "7 authentication rejected: $target takes OTLP without authentication in this environment, so there is nothing to refuse"

# 8, 9: the outage, as Vigil recorded it.
if [ -n "$bk_metrics" ]; then
    failures=$(local_value 'vigil_backend_failures_total{backend="target"')
    if [ "${failures:-0}" -gt 0 ] && [ "$queued" -gt 0 ]; then
        result PASS "8 the backend unavailable: $failures failures counted, $queued event files held in its queue, jobs ran on"
    else
        result FAIL "8 the backend unavailable: failures ${failures:-none}, queued $queued"
    fi
    # The sender's failed runs in the outage, from its own log: each began
    # 5, 10, 20, 40... seconds after the one before. A run id has the
    # second the worker started, and the backoff counts from when the
    # sender read the clock, a second or two in: 2 seconds of slack below,
    # and a tick and a sender run above.
    starts=$(grep -h 'run end failed (delivery failed: target' "$root"/logs/jobs/vigil_sender/*.log |
        awk '{ print $2 }' | sed 's/^\([0-9]\{8\}\)T\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)Z.*/\1 \2:\3:\4/' |
        while read -r d t; do date -u -d "$d $t" +%s; done | awk -v a="$t_down" -v b="$t_up" '$1 >= a && $1 < b')
    gaps=$(printf '%s\n' "$starts" | awk 'NR > 1 { printf "%s ", $1 - p } { p = $1 }')
    ok=$(printf '%s\n' "$gaps" | awk '{ e = 5; for (i = 1; i <= NF; i++) { if ($i < e - 2 || $i > e + 15) { print "no"; exit } e = (e * 2 > 300) ? 300 : e * 2 } print "yes" }')
    if [ "$ok" = yes ] && [ "$(printf '%s\n' $gaps | grep -c .)" -ge 2 ]; then
        result PASS "9 retry and backoff: the sender's failed runs ${gaps}seconds apart"
    else
        result FAIL "9 retry and backoff: failed runs ${gaps:-none }seconds apart, not 5, 10, 20... (plus slack)"
    fi
fi
if [ -n "$bk_logs" ]; then
    if [ "${fwd:-0}" -gt 0 ]; then result PASS "8, 9 logs: the forwarder failed $fwd times and backed off"; else result FAIL "8, 9 logs: no forwarder failure recorded"; fi
fi

# 10, 11, 12, 16: every run before t_main, once.
if [ -n "$prom" ]; then
    m=$(printf '%s\n' "$got" | missing) d=$(printf '%s\n' "$got" | dups)
    out=$(ledger_between "$t_down" "$t_up" | grep -c .)
    if [ "$m" -eq 0 ]; then
        result PASS "10 recovery from the spool: all $out runs of the outage arrived afterwards"
        result PASS "11 a backend restart: nothing lost across it"
        result PASS "16 a supervisor restart: nothing lost across it, the same spool carried on"
    else
        result FAIL "10, 11, 16: $m of $nwant runs never arrived: $(comm -23 <(printf '%s\n' "$want" | sort -u) <(printf '%s\n' "$got" | sort -u) | tr '\n' ' ')"
    fi
    if [ "$d" -eq 0 ]; then result PASS "12 duplicate delivery: none, $nwant runs, $nwant samples"; else result FAIL "12 duplicate delivery: $d runs stored twice"; fi
fi
if [ -n "$loki" ]; then
    m=$(printf '%s\n' "$gotl" | missing) d=$(printf '%s\n' "$gotl" | dups)
    if [ "$m" -eq 0 ]; then
        result PASS "10, 11, 16 logs: every run's line arrived, through the outage, the restart and the supervisor restart"
    else
        result FAIL "10, 11, 16 logs: $m of $nwant lines never arrived"
    fi
    if [ "$d" -eq 0 ]; then result PASS "12 duplicate delivery (logs): none"; else result FAIL "12 duplicate delivery (logs): $d lines stored twice"; fi
fi

# 13: drops counted, and reported to the backend itself once it is back.
if [ -n "$bk_metrics" ]; then
    printf '  dropped, in the file backend: %s\n' "${dropped_local:-none}"
    if [ -z "$dropped_local" ]; then
        result FAIL '13 dropped telemetry: nothing counted'
    elif [ -n "$prom" ] && jq -e '.data.result | length > 0' "$work/dropped.json" > /dev/null 2>&1; then
        result PASS "13 dropped telemetry: counted, and reported to $target once it was back ($(jq -r '[.data.result[] | "\(.metric.reason)=\(.value[1])"] | join(" ")' "$work/dropped.json"))"
    else
        result FAIL "13 dropped telemetry: counted in the file backend, but $target never got the count"
    fi
else
    result 'NOT APPLICABLE' "13 dropped telemetry: $target takes logs, and the forwarder reads Vigil's own files, which are never dropped for an outage"
fi

# 14, 15: the file backend alongside.
if [ -n "$bk_metrics" ] && [ -n "$(local_value "bk_check_seq{")" ]; then
    result PASS '14 several destinations: the same runs in the file backend and the target'
elif [ -n "$bk_metrics" ]; then
    result FAIL '14 several destinations: nothing in the file backend'
fi
if [ -n "$bk_metrics" ]; then
    if [ "$fresh" = yes ]; then result PASS '15 a healthy destination unaffected: the file backend stayed current all through the outage'; else result FAIL "15 a healthy destination unaffected: $fresh"; fi
fi

printf '%d passed, %d failed, %d not run or not applicable\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]
