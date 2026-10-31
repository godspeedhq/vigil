#!/usr/bin/env bash
#
# Integration test: the Datadog and OTLP backends (SPECIFICATION.md 15.3) on
# Linux and macOS, against mock-backend.py on this host. A run's metrics
# reach both with their credentials in headers, a failing backend keeps its
# events and backs off until it recovers, a rejected batch is dropped and
# counted, and no credential ever reaches a log, state, spool or metrics
# file.
#
# Needs python3 (or python).
#
# Exit code: 0 all passed, 1 any failed.

set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$(dirname "$here")")
vigil_cmd=$repo/app/vigil
root=${TMPDIR:-/tmp}/vigil-backends.$$
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

vigil() {
    "$BASH" "$vigil_cmd" --root "$root" "$@"
}

# One supervisor tick, then wait (up to 60s) for the sender it may have
# started.
tick() {
    local i=0
    vigil supervise --once > /dev/null 2>&1
    while ls "$root/state/locks" 2>/dev/null | grep '^vigil_sender\.' > /dev/null; do
        i=$((i + 1))
        [ "$i" -ge 120 ] && break
        sleep 0.5
    done
}

# Whether the mock's request log has a line containing every argument.
received() {
    local line a ok
    while IFS= read -r line; do
        ok=yes
        for a in "$@"; do
            case $line in *"$a"*) ;; *) ok=no; break ;; esac
        done
        [ "$ok" = yes ] && { echo yes; return 0; }
    done < "$root/mock/requests.log"
    echo no
}

queued() {
    ls "$root/spool/backends/$1" 2>/dev/null | grep -c '\.events$'
}

cleanup() {
    [ -n "$mock_pid" ] && kill "$mock_pid" 2>/dev/null
    rm -rf "$root"
}
trap cleanup EXIT

printf 'bash %s\n' "$BASH_VERSION"
# The first Python that runs: on Windows, python3 may be only a placeholder.
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

# Git Bash: the mock is a Windows program, needing a Windows path.
case $(uname -s) in
    MINGW* | MSYS* | CYGWIN*) mockdir=$(cygpath -m "$root/mock") ;;
    *) mockdir=$root/mock ;;
esac
"$python" "$here/mock-backend.py" "$mockdir" 2> "$root/mock/stderr" &
mock_pid=$!
i=0
while [ ! -s "$root/mock/port" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
port=$(cat "$root/mock/port" 2>/dev/null)
check "mock started" yes "$([ -n "$port" ] && echo yes || echo no)"
: > "$root/mock/requests.log"

dd_key="dd-it-key-$$"
otel_token="otel-it-token-$$"
export VIGIL_IT_DD_KEY=$dd_key

cat > "$root/scripts/emit.sh" <<'EOF'
echo "metric answer 42"
EOF

cat > "$root/config/vigil.config" <<EOF
[vigil]
instance = bk

[scheduler]
tick = 1s

[backend.file]
path = metrics/vigil.prom

[backend.datadog]
endpoint = http://127.0.0.1:$port
api_key  = env:VIGIL_IT_DD_KEY
timeout  = 5s

[backend.otel]
endpoint = http://127.0.0.1:$port/v1/metrics
api_key  = secret:OTEL_TOKEN
timeout  = 5s

[runner.sh]
command = /bin/sh

[runners]
.sh = sh

[job.emit]
file      = scripts/emit.sh
run_every = 3650d
EOF
printf '%s' "$otel_token" | vigil secret set OTEL_TOKEN --stdin > /dev/null

# Delivered to both, the credential in its header.
vigil run emit > /dev/null
tick
check "datadog: series API" yes "$(received '"path": "/api/v2/series"' "\"DD-API-KEY\": \"$dd_key\"" '\"metric\":\"emit.answer\",\"type\":3' '\"value\":42')"
check "datadog: host as a resource" yes "$(received '"path": "/api/v2/series"' '\"type\":\"host\"' '\"instance:bk\"' '\"job:emit\"')"
check "otel: OTLP receiver" yes "$(received '"path": "/v1/metrics"' "\"Authorization\": \"Bearer $otel_token\"" '\"name\":\"emit.answer\",\"gauge\"' '\"asDouble\":42')"
check "otel: counts as delta sums" yes "$(received '"path": "/v1/metrics"' '\"name\":\"emit.runs\",\"sum\":{\"aggregationTemporality\":1')"
check "datadog queue drained" 0 "$(queued datadog)"
check "otel queue drained" 0 "$(queued otel)"
check "sender succeeded" succeeded "$(sed -n 's/^status *= *//p' "$root/state/jobs/vigil_sender.state")"

# A failing backend keeps its events and backs off.
echo 503 > "$root/mock/status"
vigil run emit > /dev/null
tick
check "failing: datadog events kept" yes "$([ "$(queued datadog)" -gt 0 ] && echo yes || echo no)"
check "failing: otel events kept" yes "$([ "$(queued otel)" -gt 0 ] && echo yes || echo no)"
check "failing: backoff recorded" yes "$([ -f "$root/state/backends/datadog.state" ] && [ -f "$root/state/backends/otel.state" ] && echo yes || echo no)"
check "failing: reason logged" yes "$(grep -r "datadog (HTTP 503 from 127.0.0.1:$port)" "$root/logs/jobs/vigil_sender" > /dev/null && echo yes || echo no)"
check "failing: first failure counted" 1 "$(sed -n 's/^failures = //p' "$root/state/backends/datadog.state")"
# Recovered: the kept events go after the backoff, and the failures are counted.
rm -f "$root/mock/status"
sleep 6
tick
check "recovered: datadog queue drained" 0 "$(queued datadog)"
check "recovered: otel queue drained" 0 "$(queued otel)"
check "recovered: backoff cleared" no "$([ -f "$root/state/backends/datadog.state" ] && echo yes || echo no)"
tick
check "recovered: failures counted" yes "$(grep '^vigil_backend_failures_total{backend="datadog"' "$root/metrics/vigil.prom" > /dev/null && echo yes || echo no)"

# Rejected as malformed: dropped and counted, never retried.
echo 400 > "$root/mock/status"
vigil run emit > /dev/null
tick
check "rejected: datadog queue drained" 0 "$(queued datadog)"
rm -f "$root/mock/status"
tick
tick
check "rejected: drop counted" yes "$(grep '^vigil_spool_dropped_total{backend="datadog".*reason="rejected"' "$root/metrics/vigil.prom" > /dev/null && echo yes || echo no)"

# The credentials are only ever in headers: never on disk outside the
# secret store, and never in a URL.
check "no credential in logs, state, spool or metrics" "" "$(grep -rlF -e "$dd_key" -e "$otel_token" "$root/logs" "$root/state" "$root/spool" "$root/metrics" 2>/dev/null)"
check "no credential in a URL" "" "$(sed -n 's/.*"path": "\([^"]*\)".*/\1/p' "$root/mock/requests.log" | grep -F -e "$dd_key" -e "$otel_token")"

if [ "$fail" -gt 0 ]; then
    printf '\nmock stderr:\n'
    cat "$root/mock/stderr"
    printf '\nsender log:\n'
    cat "$root/logs/jobs/vigil_sender/"*.log 2>/dev/null | tail -20
fi
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
