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
#   tests/conformance/command/<case>.config       input; a name ending -windows
#                                                 uses platform windows and root
#                                                 C:\Program Files\Vigil, others
#                                                 posix and /opt/vigil
#   tests/conformance/command/<case>.expected     validate dump, then
#                                                 vigil_job_command_dump
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
# shellcheck source=../app/lib/command.sh
. "$root/app/lib/command.sh"

pass=0
fail=0

printf 'bash %s\n' "$BASH_VERSION"

for suite in parser validate effective command; do
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
            command)
                case $name in
                    *-windows) platform=windows install_root='C:\Program Files\Vigil' ;;
                    *) platform=posix install_root=/opt/vigil ;;
                esac
                actual=$(vigil_config_parse "$cfg"; vigil_config_validate; vigil_config_validate_dump
                         vigil_job_command_dump "$platform" "$install_root") ;;
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

# File-level cases need inputs that cannot be committed as fixtures: a
# missing file, and files at and over the 1 MiB limit (all "a", no newline,
# so a file at the limit is read and reports one E_NO_EQUALS).
tmp=${TMPDIR:-/tmp}/vigil-conformance.$$
mkdir -p "$tmp"
head -c "$VIGIL_CFG_MAX_BYTES" /dev/zero | tr '\0' a > "$tmp/at-limit.config"
{ cat "$tmp/at-limit.config"; printf 'a'; } > "$tmp/over-limit.config"
for check in "missing	ERROR	0	E_FILE_NOT_FOUND" \
             "at-limit	ERROR	1	E_NO_EQUALS" \
             "over-limit	ERROR	0	E_FILE_TOO_LARGE"; do
    name=${check%%	*}
    expected=${check#*	}
    actual=$(vigil_config_parse "$tmp/$name.config"; vigil_config_dump)
    if [ "$actual" = "$expected" ]; then
        pass=$((pass + 1))
        printf '  PASS  file/%s\n' "$name"
    else
        fail=$((fail + 1))
        printf '  FAIL  file/%s: expected [%s] actual [%s]\n' "$name" "$expected" "$actual"
    fi
done
rm -rf "$tmp"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
