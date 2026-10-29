#!/usr/bin/env bash
#
# Runs the shared conformance suite against the bash implementation.
# The PowerShell twin is Run-Conformance.ps1; both read the same cases and
# must pass the same expectations.
#
#   tests/conformance/parser/<case>.config    input
#   tests/conformance/parser/<case>.expected  vigil_config_dump output
#
# Exit code: 0 all passed, 1 any failed.

set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")

# shellcheck source=../app/lib/config.sh
. "$root/app/lib/config.sh"

pass=0
fail=0

printf 'bash %s\n' "$BASH_VERSION"

for cfg in "$here"/conformance/parser/*.config; do
    name=$(basename "$cfg" .config)
    expected_file=${cfg%.config}.expected

    actual=$(vigil_config_parse "$cfg"; vigil_config_dump)
    expected=$(cat "$expected_file")

    if [ "$actual" = "$expected" ]; then
        pass=$((pass + 1))
        printf '  PASS  parser/%s\n' "$name"
    else
        fail=$((fail + 1))
        printf '  FAIL  parser/%s\n' "$name"
        printf '%s\n' "$expected" > "${TMPDIR:-/tmp}/vigil-expected.$$"
        printf '%s\n' "$actual" > "${TMPDIR:-/tmp}/vigil-actual.$$"
        diff "${TMPDIR:-/tmp}/vigil-expected.$$" "${TMPDIR:-/tmp}/vigil-actual.$$" | sed 's/^/        /'
        rm -f "${TMPDIR:-/tmp}/vigil-expected.$$" "${TMPDIR:-/tmp}/vigil-actual.$$"
    fi
done

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
