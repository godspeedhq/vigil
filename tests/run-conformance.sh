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
#   tests/conformance/schedule/<case>.table       decisions table, inputs and
#                                                 expected decisions per row;
#                                                 compared with comments and
#                                                 blank lines dropped and
#                                                 columns single-spaced
#   tests/mocks/<path>.config                     the example configurations
#   tests/conformance/mocks/<path>.expected       validate dump, then
#                                                 vigil_config_effective_dump
#   tests/conformance/recovery/<case>.table       rows of evidence and expected
#                                                 vigil_recovery_conclude
#   tests/conformance/outcome/<case>.table        rows of exit_codes, exit code
#                                                 and expected vigil_outcome
#   tests/conformance/metrics/<case>.stdout       a run's stdout; -nagios in the
#                                                 name parses perfdata, a
#                                                 trailing -cap<n> sets the cap
#   tests/conformance/metrics/<case>.expected     vigil_metrics_dump output
#   tests/conformance/events/<case>.config        a configuration, with the run
#                                                 in <case>.run and its output
#                                                 in <case>.stdout
#   tests/conformance/events/<case>.expected      vigil_run_events_dump output
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
# shellcheck source=../app/lib/outcome.sh
. "$root/app/lib/outcome.sh"
# shellcheck source=../app/lib/metrics.sh
. "$root/app/lib/metrics.sh"
# shellcheck source=../app/lib/events.sh
. "$root/app/lib/events.sh"
# shellcheck source=../app/lib/recovery.sh
. "$root/app/lib/recovery.sh"

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

# A three-column table without comments or blank lines, single-spaced.
table_rows3() {
    local a b c
    while read -r a b c || [ -n "$a" ]; do
        case $a in '' | '#'*) continue ;; esac
        printf '%s %s %s\n' "$a" "$b" "$c"
    done < "$1"
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

# The example configurations in tests/mocks, every tier: each must give the
# validate dump and vigil_config_effective_dump recorded in
# tests/conformance/mocks/<path>.expected.
for cfg in $(find "$here/mocks" -name '*.config' | LC_ALL=C sort); do
    rel=${cfg#"$here/mocks/"}
    actual=$(vigil_config_parse "$cfg"; vigil_config_validate; vigil_config_validate_dump; vigil_config_effective_dump)
    compare "mocks/${rel%.config}" "$(cat "$here/conformance/mocks/${rel%.config}.expected")" "$actual"
done

# Exit code classification: each table row is "<exit_codes> <code>
# <outcome>", and the case passes when every row gives its outcome.
for table in "$here"/conformance/outcome/*.table; do
    expected=$(table_rows3 "$table")
    actual=$(table_rows3 "$table" | while read -r spec code want; do
        vigil_outcome "$spec" "$code"
        printf '%s %s %s\n' "$spec" "$code" "$VIGIL_OUTCOME"
    done)
    compare "outcome/$(basename "$table" .table)" "$expected" "$actual"
done

# Recovery conclusions: each table row is the evidence and the expected
# conclusion; the case passes when every row gives its conclusion.
for table in "$here"/conformance/recovery/*.table; do
    expected=$(while read -r a b c d e f g || [ -n "$a" ]; do
        case $a in '' | '#'*) continue ;; esac
        printf '%s %s %s %s %s %s %s\n' "$a" "$b" "$c" "$d" "$e" "$f" "$g"
    done < "$table")
    compare "recovery/$(basename "$table" .table)" "$expected" "$(vigil_recovery_table_dump "$table")"
done

# Job output: <case>.stdout parsed with mode nagios when the name contains
# -nagios, and with the cap given by a trailing -cap<n>, else the default.
for out in "$here"/conformance/metrics/*.stdout; do
    name=$(basename "$out" .stdout)
    mode=standard
    case $name in *-nagios*) mode=nagios ;; esac
    cap=$VIGIL_METRIC_LINES_MAX
    case $name in *-cap[0-9]*) cap=${name##*-cap} ;; esac
    actual=$(vigil_metrics_parse "$mode" "$cap" "$out"; vigil_metrics_dump)
    compare "metrics/$name" "$(cat "$here/conformance/metrics/$name.expected")" "$actual"
done

# Run events: <case>.config, the run in <case>.run ("<key> <value>" lines:
# job, epoch, mode, outcome, exit_code, duration, host, os) and its output
# in <case>.stdout.
for cfg in "$here"/conformance/events/*.config; do
    name=$(basename "$cfg" .config)
    while read -r key value || [ -n "$key" ]; do
        case $key in
            job) r_job=$value ;; epoch) r_epoch=$value ;; mode) r_mode=$value ;;
            outcome) r_outcome=$value ;; exit_code) r_code=$value ;;
            duration) r_duration=$value ;; host) r_host=$value ;; os) r_os=$value ;;
        esac
    done < "${cfg%.config}.run"
    actual=$(vigil_config_parse "$cfg"; vigil_config_validate
             vigil_metrics_parse "$r_mode" "$VIGIL_METRIC_LINES_MAX" "${cfg%.config}.stdout"
             vigil_run_events "$r_job" "$r_epoch" "$r_outcome" "$r_code" "$r_duration" "$r_host" "$r_os"
             vigil_run_events_dump)
    compare "events/$name" "$(cat "${cfg%.config}.expected")" "$actual"
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
# A run printing more metric lines than the default cap: the excess is
# dropped and counted.
i=0
while [ "$i" -lt $((VIGIL_METRIC_LINES_MAX + 5)) ]; do
    printf 'metric m 1\n'
    i=$((i + 1))
done > "$tmp/flood.stdout"
compare file/metric-flood "SUMMARY metric_lines=$VIGIL_METRIC_LINES_MAX invalid_lines=0 dropped_lines=5" \
    "$(vigil_metrics_parse standard "$VIGIL_METRIC_LINES_MAX" "$tmp/flood.stdout"; vigil_metrics_dump | tail -n 1)"
rm -rf "$tmp"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
