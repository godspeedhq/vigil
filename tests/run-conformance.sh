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
#   tests/conformance/schedule/<case>.config      input
#   tests/conformance/files/<case>/files.list     several files read as one
#                                                 configuration, in order
#   tests/conformance/files/<case>/case.expected  validate dump, then
#                                                 vigil_config_effective_dump
#   tests/conformance/schedule/<case>.table       decisions table, inputs and
#                                                 expected decisions per row;
#                                                 compared with comments and
#                                                 blank lines dropped and
#                                                 columns single-spaced
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
# shellcheck source=../app/lib/schedule.sh
. "$root/app/lib/schedule.sh"

pass=0
fail=0

printf 'bash %s\n' "$BASH_VERSION"

# A decisions table as the runner expects it: no comments or blank lines,
# columns separated by one space.
table_rows() {
    local a b c d e f g h
    while read -r a b c d e f g h || [ -n "$a" ]; do
        case $a in '' | '#'*) continue ;; esac
        printf '%s %s %s %s %s %s %s %s\n' "$a" "$b" "$c" "$d" "$e" "$f" "$g" "$h"
    done < "$1"
}

# compare <name> <expected> <actual>: counts and reports one case.
compare() {
    if [ "$3" = "$2" ]; then
        pass=$((pass + 1))
        printf '  PASS  %s\n' "$1"
    else
        fail=$((fail + 1))
        printf '  FAIL  %s\n' "$1"
        printf '%s\n' "$2" > "${TMPDIR:-/tmp}/vigil-expected.$$"
        printf '%s\n' "$3" > "${TMPDIR:-/tmp}/vigil-actual.$$"
        diff "${TMPDIR:-/tmp}/vigil-expected.$$" "${TMPDIR:-/tmp}/vigil-actual.$$" | sed 's/^/        /'
        rm -f "${TMPDIR:-/tmp}/vigil-expected.$$" "${TMPDIR:-/tmp}/vigil-actual.$$"
    fi
}

for suite in parser validate effective command schedule; do
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
            schedule)
                expected_file=${cfg%.config}.table
                actual=$(vigil_config_parse "$cfg"; vigil_config_validate; vigil_config_validate_dump
                         vigil_schedule_table_dump "$expected_file") ;;
        esac
        if [ "$suite" = schedule ]; then
            expected=$(table_rows "$expected_file")
        else
            expected=$(cat "$expected_file")
        fi

        compare "$suite/$name" "$expected" "$actual"
    done
done

# Multi-file cases: a folder per case, with files.list naming each file in
# order as "<role> <label> <path>" (label - for the main file), and
# case.expected holding the validate dump, then vigil_config_effective_dump.
for dir in "$here"/conformance/files/*/; do
    dir=${dir%/}
    set --
    while read -r role label path || [ -n "$role" ]; do
        case $role in '' | '#'*) continue ;; esac
        set -- "$@" "$role" "$label" "$dir/$path"
    done < "$dir/files.list"
    actual=$(vigil_config_parse_files "$@"; vigil_config_validate; vigil_config_validate_dump; vigil_config_effective_dump)
    compare "files/$(basename "$dir")" "$(cat "$dir/case.expected")" "$actual"
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
# One file over the limit on the number of configuration files.
printf '[job.a]\n' > "$tmp/small.config"
set -- main - "$tmp/small.config"
i=1
while [ "$i" -le "$VIGIL_CFG_MAX_FILES" ]; do
    set -- "$@" dropin "jobs.d/$i.config" "$tmp/small.config"
    i=$((i + 1))
done
compare file/too-many-files "ERROR	0	E_TOO_MANY_FILES" "$(vigil_config_parse_files "$@"; vigil_config_dump)"
rm -rf "$tmp"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
