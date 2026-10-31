#!/usr/bin/env bash
#
# Integration test: secrets at run time (SPECIFICATION.md 6.5) on Linux and
# macOS. Sets secrets with vigil secret, runs a job that receives them from
# Vigil's store, a helper store and the environment, rotates them and sees
# the very next run use the new values with no restart, and checks the
# failure cases. No value may ever appear in a log, state or spool file.
#
# Exit code: 0 all passed, 1 any failed.

set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$(dirname "$here")")
vigil_cmd=$repo/app/vigil
root=${TMPDIR:-/tmp}/vigil-sec.$$
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

state_value() {
    sed -n "s/^$2 *= \{0,1\}//p" "$1"
}

vigil() {
    "$BASH" "$vigil_cmd" --root "$root" "$@"
}

# The value of metric $2 in job $1's latest events.
metric() {
    local f
    f=$(ls "$root/spool/incoming/"*"-$1-"*.events 2>/dev/null | tail -n 1)
    [ -n "$f" ] && sed -n "s/^[0-9]* $1\\.$2 \\([^ ]*\\) .*/\\1/p" "$f"
}

printf 'bash %s\n' "$BASH_VERSION"
mkdir -p "$root/config" "$root/scripts" "$root/expect"
root=$(cd "$root" && pwd)
case $(uname -s) in MINGW* | MSYS* | CYGWIN*) unixperms=0 ;; *) unixperms=1 ;; esac

# The job reports, for each secret, whether it received exactly the value
# the test expects - never the value itself.
cat > "$root/scripts/show.sh" <<'EOF'
same() { if [ "$1" = "$(cat "$IT_ROOT/expect/$2")" ]; then echo 1; else echo 0; fi; }
echo "metric pg_ok $(same "${PGPASSWORD-}" pg)"
echo "metric api_ok $(same "${API_TOKEN-}" api)"
echo "metric region_ok $(same "${REGION_KEY-}" region)"
EOF
# A helper store: prints the value of "api-token" from a file it can rotate.
cat > "$root/scripts/helper.sh" <<'EOF'
[ "$1" = get ] || exit 64
case $2 in
    api-token) cat "$(dirname "$0")/../helper-value" ;;
    slow) sleep 30 ;;
    *) exit 2 ;;
esac
EOF
chmod +x "$root/scripts/helper.sh"

cat > "$root/config/vigil.config" <<EOF
[runner.sh]
command = /bin/sh

[runners]
.sh = sh

[secret_store.ext]
type    = helper
command = scripts/helper.sh
timeout = 2s

[job.show]
file        = scripts/show.sh
run_every   = 1h
env         = IT_ROOT=$root
secret      = PGPASSWORD=secret:PGPASSWORD
secret      = API_TOKEN=store:ext/api-token
secret      = REGION_KEY=env:IT_REGION_KEY
require_env = PGPASSWORD

[job.missing_secret]
file      = scripts/show.sh
run_every = 1h
secret    = X=secret:NO_SUCH_SECRET

[job.helper_fails]
file      = scripts/show.sh
run_every = 1h
secret    = X=store:ext/unknown

[job.helper_slow]
file      = scripts/show.sh
run_every = 1h
secret    = X=store:ext/slow
EOF

# 1. Set secrets; the store is owner-only; list shows names, never values.
printf 'first pg value\n' | vigil secret set PGPASSWORD --stdin > /dev/null
check "secret set" 0 "$?"
printf 'first pg value' > "$root/expect/pg"
printf 'api-1 %s' "$$" > "$root/helper-value"
printf 'api-1 %s' "$$" > "$root/expect/api"
printf 'eu-west' > "$root/expect/region"
if [ "$unixperms" -eq 1 ]; then
    check "store folder is 0700" drwx------ "$(ls -ld "$root/config/secrets" | cut -c1-10)"
    check "secret file is 0600" -rw------- "$(ls -l "$root/config/secrets/PGPASSWORD" | cut -c1-10)"
fi
check "list shows the name" yes "$(vigil secret list | grep '^PGPASSWORD ' > /dev/null && echo yes || echo no)"
check "list never shows the value" "" "$(vigil secret list | grep 'first pg value')"

# 2. A run receives all three, each exactly.
IT_REGION_KEY=eu-west vigil run show > /dev/null 2>&1
check "run with secrets succeeds" 0 "$?"
check "secret: delivered exactly" 1 "$(metric show pg_ok)"
check "store: (helper) delivered exactly" 1 "$(metric show api_ok)"
check "env: delivered exactly" 1 "$(metric show region_ok)"

# 3. Rotate: the very next run uses the new values. Nothing restarts.
printf 'second, longer pg value' | vigil secret set PGPASSWORD --stdin > /dev/null
printf 'second, longer pg value' > "$root/expect/pg"
printf 'api-2 %s' "$$" > "$root/helper-value"
printf 'api-2 %s' "$$" > "$root/expect/api"
IT_REGION_KEY=eu-west vigil run show > /dev/null 2>&1
check "rotated secret: used by the next run" 1 "$(metric show pg_ok)"
check "rotated store: secret used by the next run" 1 "$(metric show api_ok)"

# 4. Failures fail the run before it starts, naming the reference only.
vigil run missing_secret > /dev/null 2>&1
check "missing secret fails the run" failed "$(state_value "$root/state/jobs/missing_secret.state" status)"
check "missing secret reason" "secret secret:NO_SUCH_SECRET unavailable: not found in Vigil's secret store (vigil secret set NO_SUCH_SECRET)" \
    "$(state_value "$root/state/jobs/missing_secret.state" reason)"
vigil run helper_fails > /dev/null 2>&1
check "failing helper reason" "secret store:ext/unknown unavailable: the helper failed (exit code 2)" \
    "$(state_value "$root/state/jobs/helper_fails.state" reason)"
vigil run helper_slow > /dev/null 2>&1
check "slow helper stopped at its timeout" "secret store:ext/slow unavailable: the helper was stopped after 2s" \
    "$(state_value "$root/state/jobs/helper_slow.state" reason)"
vigil run show > /dev/null 2>&1
check "unset env: reference reason" "secret env:IT_REGION_KEY unavailable: not set in the environment" \
    "$(state_value "$root/state/jobs/show.state" reason)"

# 5. A secret others could read is refused, not used.
if [ "$unixperms" -eq 1 ]; then
    chmod 644 "$root/config/secrets/PGPASSWORD"
    IT_REGION_KEY=eu-west vigil run show > /dev/null 2>&1
    check "readable by others: refused" yes "$(state_value "$root/state/jobs/show.state" reason | grep '^secret secret:PGPASSWORD unavailable: refused: ' > /dev/null && echo yes || echo no)"
    chmod 600 "$root/config/secrets/PGPASSWORD"
fi

# 6. delete removes it.
vigil secret delete PGPASSWORD > /dev/null
check "delete" "" "$(vigil secret list | grep '^PGPASSWORD ')"

# No value ever reached a log, state or spool file.
leaks=$(grep -r -l -e 'first pg value' -e 'second, longer pg value' -e "api-1 $$" -e "api-2 $$" \
    "$root/logs" "$root/state" "$root/spool" 2>/dev/null)
check "no value in any log, state or spool file" "" "$leaks"

rm -rf "$root"
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
