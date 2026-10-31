#!/usr/bin/env bash
#
# Integration test: vigil precheck (SPECIFICATION.md 16.3, 16.4) on Linux
# and macOS, and the supervisor refusing to start with the full list of
# problems. Precheck must change nothing and never print a secret's value.
#
# Exit code: 0 all passed, 1 any failed.

set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$(dirname "$here")")
vigil_cmd=$repo/app/vigil
root=${TMPDIR:-/tmp}/vigil-pre.$$
pass=0
fail=0

check() {
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
        printf '  PASS  %s\n' "$1"
    else
        fail=$((fail + 1))
        printf '  FAIL  %s: expected [%s] actual [%s]\n' "$1" "$2" "$3"
    fi
}

# Whether the output in $out has the line $1 exactly.
has() {
    if printf '%s\n' "$out" | grep -F -x -e "$1" > /dev/null; then echo yes; else echo no; fi
}

vigil() {
    "$BASH" "$vigil_cmd" --root "$root" "$@"
}

printf 'bash %s\n' "$BASH_VERSION"
mkdir -p "$root/config" "$root/scripts"
root=$(cd "$root" && pwd)
printf 'echo "metric ok 1"\n' > "$root/scripts/ok.sh"

good_config() {
    cat > "$root/config/vigil.config" <<EOF
[runner.sh]
command = /bin/sh

[runners]
.sh = sh

[secret_store.vault]
type  = hashicorp_vault
url   = https://vault.example.com
auth  = token
token = secret:VAULT_TOKEN

[job.show]
file        = scripts/ok.sh
run_every   = 1h
secret      = PGPASSWORD=secret:PGPASSWORD
require_env = PGPASSWORD
require_env = HOME
EOF
}

# 1. Everything in place: passes, and changes nothing.
good_config
printf 'pg value %s' "$$" | vigil secret set PGPASSWORD --stdin > /dev/null
printf 'vault value %s' "$$" | vigil secret set VAULT_TOKEN --stdin > /dev/null
out=$(vigil precheck 2>&1)
check "passes: exit code" 0 "$?"
check "passes: no configuration problems" yes "$(has '  no problems')"
check "passes: the job" yes "$(has '  ok    job.show')"
check "passes: a store credential, by reference" yes "$(has '  ok    secret_store.vault: token secret:VAULT_TOKEN')"
check "passes: result" yes "$(has 'precheck passed')"
check "changes nothing" "config scripts" "$(ls "$root" | tr '\n' ' ' | sed 's/ $//')"

# 2. With a job: its effective settings and their sources.
out=$(vigil precheck show 2>&1)
check "job: exit code" 0 "$?"
check "job: header" yes "$(has 'job.show')"
check "job: runner from the extension map" yes "$(has '  runner            = sh                     (runners)')"
check "job: secret by reference" yes "$(has '  secret            = PGPASSWORD=secret:PGPASSWORD (job)')"
out=$(vigil precheck nosuch 2>&1)
check "unknown job: exit code" 1 "$?"
check "unknown job: result" yes "$(has 'precheck failed: no job nosuch in the configuration')"

# 3. What a run would trip on, each reported, nothing else stopped.
cat >> "$root/config/vigil.config" <<EOF

[runner.gone]
command = /nonexistent/bin/tool

[job.broken]
file        = scripts/missing.sh
runner      = gone
run_every   = 1h
working_dir = no/such/dir
secret      = X=secret:NO_SUCH_SECRET
require_env = VIGIL_IT_SURELY_UNSET
EOF
vigil secret delete VAULT_TOKEN > /dev/null
out=$(VIGIL_FAULT=crash vigil precheck 2>&1)
check "fails: exit code" 1 "$?"
check "fails: the good job still passes" yes "$(has '  ok    job.show')"
check "fails: working directory" yes "$(has "  FAIL  job.broken: working directory not found: $root/no/such/dir")"
check "fails: runner command" yes "$(has '  FAIL  job.broken: not found: /nonexistent/bin/tool')"
check "fails: job file" yes "$(has "  FAIL  job.broken: file not found: $root/scripts/missing.sh")"
check "fails: secret" yes "$(has "  FAIL  job.broken: secret secret:NO_SUCH_SECRET unavailable: not found in Vigil's secret store (vigil secret set NO_SUCH_SECRET)")"
check "fails: require_env" yes "$(has '  FAIL  job.broken: missing environment variable VIGIL_IT_SURELY_UNSET')"
check "fails: store credential" yes "$(has "  FAIL  secret_store.vault: token secret:VAULT_TOKEN unavailable: not found in Vigil's secret store (vigil secret set VAULT_TOKEN)")"
check "fails: VIGIL_FAULT" yes "$(has '  FAIL  VIGIL_FAULT is set: fault injection is for tests only (22.4.1)')"
check "fails: result" yes "$(has 'precheck failed: 7 problem(s)')"
check "no secret value printed" "" "$(printf '%s\n' "$out" | grep -e "pg value $$" -e "vault value $$")"

# 4. A rejected configuration: every problem, in file order, and nothing else.
printf '[vigil]\nmax_concurrent = 0\n\n[job.x]\nfile = a.sh\n\n[weird]\n' > "$root/config/vigil.config"
out=$(vigil precheck 2>&1)
check "rejected: exit code" 1 "$?"
check "rejected: first problem" yes "$(has "  ERROR    line 2: 'max_concurrent' must be at least 1 (E_INTEGER)")"
check "rejected: invalid job" yes "$(has '  INVALID  job.x, line 4: [job.x] needs run_every or run_at (E_SCHEDULE_NONE)')"
check "rejected: last problem" yes "$(has '  ERROR    line 7: unknown section [weird] (E_SECTION_UNKNOWN)')"
check "rejected: result" yes "$(has 'precheck failed: the configuration is rejected; nothing else was checked')"

# 5. The supervisor will not start, and says why, in full.
out=$(vigil supervise --once 2>&1)
check "supervisor refuses: exit code" 1 "$?"
check "supervisor refuses: summary" yes "$(has 'vigil: the configuration has errors; run vigil precheck')"
check "supervisor refuses: every problem" yes "$(has "  ERROR    line 2: 'max_concurrent' must be at least 1 (E_INTEGER)")"

rm -rf "$root"
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
