#!/usr/bin/env bash
#
# Integration test: forwarding Vigil's own logs (SPECIFICATION.md 13.4) on
# Linux and macOS, against mock-backend.py as an OTLP/HTTP receiver on this
# host. What is forwarded and what stays local, checkpoints that move only
# on acceptance, every failure the destination can give, and every kind of
# gap.
#
# Needs python3 (or python).
#
# Exit code: 0 all passed, 1 any failed.

set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$(dirname "$here")")
vigil_cmd=$repo/app/vigil
root=${TMPDIR:-/tmp}/vigil-logs.$$
pass=0
fail=0
mock_pid=''

check() {
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
        printf '  PASS  %s\n' "$1"
    else
        fail=$((fail + 1))
        printf '  FAIL  %s: expected [%s] actual [%s]\n' "$1" "$2" "$3"
    fi
}

yes_no() { if "$@" > /dev/null 2>&1; then echo yes; else echo no; fi; }

vigil() {
    "$BASH" "$vigil_cmd" --root "$root" "$@"
}

# One supervisor tick, then wait (up to 60s) for the workers it started.
tick() {
    local i=0
    vigil supervise --once > /dev/null 2>&1
    while ls "$root/state/locks" 2>/dev/null | grep '^vigil_\(logs\|sender\)\.' > /dev/null; do
        i=$((i + 1))
        [ "$i" -ge 120 ] && break
        sleep 0.5
    done
}

# A forwarder run now: its schedule and any backoff are forgotten, and a
# line is added so that a log has grown.
forward() {
    sed -i.bak -e 's/^checked_epoch = .*/checked_epoch = 0/' -e 's/^next_try = .*/next_try = 0/' -e 's/^total = .*/total = 0/' \
        "$root/state/logs/forwarder.state" 2>/dev/null
    rm -f "$root/state/logs/forwarder.state.bak"
    tick
}

# How many requests the mock received holding the text.
received() { grep -cF -- "$1" "$root/mock/requests.log"; }
reason() { sed -n 's/^reason *= *//p' "$root/state/jobs/vigil_logs.state" 2>/dev/null; }
status() { sed -n 's/^status *= *//p' "$root/state/jobs/vigil_logs.state" 2>/dev/null; }
prom() { yes_no grep -Eq "$1" "$root/metrics/vigil.prom"; }

cleanup() {
    [ -n "$mock_pid" ] && kill "$mock_pid" 2>/dev/null
    rm -rf "$root"
}
trap cleanup EXIT

printf 'bash %s\n' "$BASH_VERSION"
python=''
for p in python3 python; do
    if "$p" -c 'import http.server' > /dev/null 2>&1; then
        python=$p
        break
    fi
done
[ -n "$python" ] || { echo "needs python3"; exit 1; }
mkdir -p "$root/config" "$root/scripts" "$root/mock"
root=$(cd "$root" && pwd)

case $(uname -s) in
    MINGW* | MSYS* | CYGWIN*) mockdir=$(cygpath -m "$root/mock") ;;
    *) mockdir=$root/mock ;;
esac
"$python" "$here/mock-backend.py" "$mockdir" 2> "$root/mock/stderr" &
mock_pid=$!
i=0
while [ ! -s "$root/mock/port" ] && [ "$i" -lt 600 ]; do sleep 0.1; i=$((i + 1)); done
port=$(cat "$root/mock/port" 2>/dev/null)
check "mock started" yes "$([ -n "$port" ] && echo yes || echo no)"
if [ -z "$port" ]; then
    cat "$root/mock/stderr"
    exit 1
fi
: > "$root/mock/requests.log"

token="logs-token-$$"
export VIGIL_IT_LOGS_AUTH="Bearer $token"

cat > "$root/scripts/chatty.sh" <<'EOF'
echo "hello from chatty"
echo "chatty on stderr" >&2
EOF
cat > "$root/scripts/quiet.sh" <<'EOF'
echo "private output of quiet"
EOF

config() {
    cat <<EOF
[vigil]
instance = lg

[scheduler]
tick = 1s

[backend.file]
path = metrics/vigil.prom

[runner.sh]
command = /bin/sh

[runners]
.sh = sh

[log_forward]
destination = ${1:-ops}
include     = supervisor, run, stdout
check_every = 1s

[log_destination.ops]
type         = otel
endpoint     = http://127.0.0.1:$port/v1/logs
header_name  = Authorization
header_value = env:VIGIL_IT_LOGS_AUTH
timeout      = 5s

[log_destination.other]
type     = otel
endpoint = http://127.0.0.1:$port/other/v1/logs

[job.chatty]
file      = scripts/chatty.sh
run_every = 3650d

[job.quiet]
file           = scripts/quiet.sh
run_every      = 3650d
forward_output = false
EOF
}
config > "$root/config/vigil.config"

check "precheck" 0 "$(vigil precheck > /dev/null 2>&1; echo $?)"
vigil run chatty > /dev/null
vigil run quiet > /dev/null
tick
tick

# What reaches the destination.
check "delivered" succeeded "$(status)"
check "the OTLP logs path" yes "$(yes_no grep -q '"path": "/v1/logs"' "$root/mock/requests.log")"
check "the credential in its header" yes "$(yes_no grep -qF "\"Authorization\": \"Bearer $token\"" "$root/mock/requests.log")"
check "stdout, as asked" 1 "$(received 'hello from chatty')"
check "the job and run named" yes "$(yes_no grep -F '\"key\":\"job\",\"value\":{\"stringValue\":\"chatty\"}' "$root/mock/requests.log")"
check "run lines" yes "$(yes_no grep -F '\"stringValue\":\"end succeeded in' "$root/mock/requests.log")"
check "supervisor lines" yes "$(yes_no grep -F '\"category\",\"value\":{\"stringValue\":\"supervisor\"}' "$root/mock/requests.log")"
check "the resource" yes "$(yes_no grep -F '\"key\":\"instance\",\"value\":{\"stringValue\":\"lg\"}' "$root/mock/requests.log")"
check "the revision" yes "$(yes_no grep -F '\"key\":\"config.revision\"' "$root/mock/requests.log")"
check "stderr stays local: not in include" 0 "$(received 'chatty on stderr')"
check "forward_output = false stays local" 0 "$(received 'private output of quiet')"
check "but the job's run lines go" yes "$(yes_no grep -F '\"key\":\"job\",\"value\":{\"stringValue\":\"quiet\"}' "$root/mock/requests.log")"
check "local logs untouched" yes "$(yes_no grep -rq 'private output of quiet' "$root/logs/jobs/quiet")"
ck=$(ls "$root"/state/logs/*chatty*.checkpoint 2>/dev/null | head -1)
check "a checkpoint per file" yes "$(yes_no test -f "$ck")"
check "metrics: records sent" yes "$(prom '^vigil_logs_records_sent_total')"
check "metrics: enabled" yes "$(prom '^vigil_logs_enabled')"

# Nothing is sent twice.
forward
check "not sent twice" 1 "$(received 'hello from chatty')"

# The forwarder's own log is never forwarded.
check "its own log stays local" 0 "$(received 'vigil_logs/')"

# A failing destination keeps what it has not taken, and backs off.
echo 503 > "$root/mock/status"
cat >> "$root/logs/jobs/chatty/$(ls "$root/logs/jobs/chatty" | tail -1)" <<EOF
2026-10-30T15:07:35Z 20261030T150733Z-1 out after the outage
EOF
forward
check "503: fetch failed" failed "$(status)"
check "503: reason" yes "$(reason | grep -q 'HTTP 503' && echo yes || echo no)"
check "503: backoff recorded" yes "$(sed -n 's/^next_try = //p' "$root/state/logs/forwarder.state" | grep -qv '^0$' && echo yes || echo no)"
tick
tick
check "503: counted" yes "$(prom '^vigil_logs_failures_total.*reason="unreachable"')"
check "503: pending" yes "$(prom '^vigil_logs_pending_bytes')"
rm -f "$root/mock/status"
: > "$root/mock/requests.log"
forward
check "recovered: resent" 1 "$(received 'after the outage')"

# A rejected login is reported as such.
echo 401 > "$root/mock/status"
forward
check "401: reported" yes "$(reason | grep -q 'permission denied' && echo yes || echo no)"
rm -f "$root/mock/status"
forward

# Accepted in part: only the leading records count.
log=$root/logs/jobs/chatty/$(ls "$root/logs/jobs/chatty" | tail -1)
printf '2026-10-30T15:07:35Z 20261030T150733Z-1 out part one\n2026-10-30T15:07:35Z 20261030T150733Z-1 out part two\n' >> "$log"
printf '{"partialSuccess":{"rejectedLogRecords":1}}' > "$root/mock/reply"
: > "$root/mock/requests.log"
forward
check "partial: reported" yes "$(reason | grep -q 'rejected 1 of' && echo yes || echo no)"
rm -f "$root/mock/reply"
: > "$root/mock/requests.log"
forward
check "partial: the rest retried" 0 "$(received 'part one')"
check "partial: the last record resent" 1 "$(received 'part two')"

# An answer Vigil cannot interpret is a failure, never a success.
printf '2026-10-30T15:07:35Z 20261030T150733Z-1 out not understood\n' >> "$log"
echo '<html>ok</html>' > "$root/mock/reply"
forward
check "invalid response: failed" yes "$(reason | grep -q 'not OTLP' && echo yes || echo no)"
rm -f "$root/mock/reply"
: > "$root/mock/requests.log"
forward
check "invalid response: resent" 1 "$(received 'not understood')"

# An incomplete last line waits for its newline.
printf '2026-10-30T15:07:35Z 20261030T150733Z-1 out half a' >> "$log"
: > "$root/mock/requests.log"
forward
check "incomplete line: held back" 0 "$(received 'half a')"
printf ' line\n' >> "$log"
forward
check "incomplete line: sent whole" 1 "$(received 'half a line')"

# Gaps: an unreadable checkpoint sends the file again.
: > "$root/mock/requests.log"
ck=$(ls "$root"/state/logs/*chatty*.checkpoint | head -1)
echo garbage > "$ck"
forward
check "checkpoint reset: sent again" yes "$(yes_no grep -q 'hello from chatty' "$root/mock/requests.log")"
tick
tick
check "checkpoint reset: reported" yes "$(prom '^vigil_logs_gaps_total.*reason="checkpoint_reset"')"

# A file replaced under its checkpoint.
: > "$root/mock/requests.log"
printf '2026-10-30T15:07:35Z 20261030T150733Z-2 out a new first line\n' > "$log"
forward
check "replaced: sent from the start" 1 "$(received 'a new first line')"
tick
tick
check "replaced: reported" yes "$(prom '^vigil_logs_gaps_total.*reason="replaced"')"

# A file deleted before it was all delivered.
echo 503 > "$root/mock/status"
printf '2026-10-30T15:07:35Z 20261030T150733Z-2 out never delivered\n' >> "$log"
forward
ck=$(ls "$root"/state/logs/*chatty*.checkpoint | head -1)
sed -i.bak 's/^size .*/size        = 999999/' "$ck" && rm -f "$ck.bak"
rm -f "$log" "$root/mock/status"
forward
check "deleted: checkpoint removed" no "$(yes_no test -f "$ck")"
tick
tick
check "deleted: reported" yes "$(prom '^vigil_logs_gaps_total.*reason="deleted"')"

# A new destination starts at the end of every file.
vigil run chatty > /dev/null
config other > "$root/config/vigil.config"
: > "$root/mock/requests.log"
tick
forward
check "destination changed: no history" 0 "$(received 'hello from chatty')"
tick
check "destination changed: reported" yes "$(prom '^vigil_logs_gaps_total.*reason="destination_changed"')"
vigil run chatty > /dev/null
forward
check "destination changed: new lines go there" yes "$(yes_no grep -q '"path": "/other/v1/logs"' "$root/mock/requests.log")"

# Turned off, nothing more is forwarded.
config ops | sed 's/^destination = ops/destination = ops\nenabled     = false/' > "$root/config/vigil.config"
tick
vigil run chatty > /dev/null
: > "$root/mock/requests.log"
forward
check "disabled: nothing sent" 0 "$(wc -l < "$root/mock/requests.log" | tr -d ' ')"

# Retention: old files go, whole, by the job's own setting if it has one.
printf 'log_retain_days = 99999\n\n[log]\nretain_days = 3\n' >> "$root/config/vigil.config"
mkdir -p "$root/logs/jobs/gone"
for f in supervisor/2020-01-01.log supervisor/2020-01-01.1.log jobs/chatty/2020-01-01.log jobs/quiet/2020-01-01.log jobs/gone/2020-01-01.log; do
    echo old > "$root/logs/$f"
done
tick
check "retention: old supervisor log" no "$(yes_no test -e "$root/logs/supervisor/2020-01-01.log")"
check "retention: its numbered part" no "$(yes_no test -e "$root/logs/supervisor/2020-01-01.1.log")"
check "retention: old job log" no "$(yes_no test -e "$root/logs/jobs/chatty/2020-01-01.log")"
check "retention: a job no longer configured" no "$(yes_no test -e "$root/logs/jobs/gone/2020-01-01.log")"
check "retention: log_retain_days wins" yes "$(yes_no test -e "$root/logs/jobs/quiet/2020-01-01.log")"
check "retention: today's log stays" yes "$(yes_no test -e "$root/logs/supervisor/$(date '+%Y-%m-%d').log")"
check "retention: the status file stays" yes "$(yes_no test -e "$root/logs/supervisor/jobs.log")"

# The credential is only ever in a header.
check "no credential in logs, state, spool or metrics" "" "$(grep -rlF "$token" "$root/logs" "$root/state" "$root/spool" "$root/metrics" 2>/dev/null)"

if [ "$fail" -gt 0 ]; then
    printf '\nforwarder log:\n'
    cat "$root/logs/jobs/vigil_logs/"*.log 2>/dev/null | tail -30
    printf '\nforwarder state:\n'
    cat "$root/state/logs/forwarder.state" "$root/state/jobs/vigil_logs.state" 2>/dev/null
fi
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
