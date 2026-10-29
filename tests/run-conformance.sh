#!/usr/bin/env bash
#
# Runs the shared conformance suite against the bash implementation.
# The PowerShell twin is Run-Conformance.ps1; both read the same cases and
# must pass the same expectations.
#
#   tests/conformance/parser/<case>.config      input
#   tests/conformance/parser/<case>.expected    vigil_config_dump output
#   tests/conformance/validate/<case>.config    input
#   tests/conformance/validate/<case>.expected  vigil_config_validate_dump output
#   tests/conformance/effective/<case>.config     input
#   tests/conformance/effective/<case>.expected   validate dump, then
#                                                 vigil_config_effective_dump
#
# Exit code: 0 all passed, 1 any failed.

set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")

# shellcheck source=../app/lib/config.sh
. "$root/app/lib/config.sh"
# shellcheck source=../app/lib/validate.sh
. "$root/app/lib/validate.sh"
# shellcheck source=../app/lib/effective.sh
. "$root/app/lib/effective.sh"

pass=0
fail=0

printf 'bash %s\n' "$BASH_VERSION"

for suite in parser validate effective; do
    for cfg in "$here"/conformance/$suite/*.config; do
        name=$(basename "$cfg" .config)
        expected_file=${cfg%.config}.expected

        case $suite in
            parser)
                actual=$(vigil_config_parse "$cfg"; vigil_config_dump) ;;
            validate)
                actual=$(vigil_config_parse "$cfg"; vigil_config_validate; vigil_config_validate_dump) ;;
            effective)
                actual=$(vigil_config_parse "$cfg"; vigil_config_validate; vigil_config_validate_dump; vigil_config_effective_dump) ;;
        esac
        expected=$(cat "$expected_file")

        if [ "$actual" = "$expected" ]; then
            pass=$((pass + 1))
            printf '  PASS  %s/%s\n' "$suite" "$name"
        else
            fail=$((fail + 1))
            printf '  FAIL  %s/%s\n' "$suite" "$name"
            printf '%s\n' "$expected" > "${TMPDIR:-/tmp}/vigil-expected.$$"
            printf '%s\n' "$actual" > "${TMPDIR:-/tmp}/vigil-actual.$$"
            diff "${TMPDIR:-/tmp}/vigil-expected.$$" "${TMPDIR:-/tmp}/vigil-actual.$$" | sed 's/^/        /'
            rm -f "${TMPDIR:-/tmp}/vigil-expected.$$" "${TMPDIR:-/tmp}/vigil-actual.$$"
        fi
    done
done

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
