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
#   tests/conformance/prom/<case>.prom            a file backend file before; with
#                                                 <case>.events, vigil_prom_merge
#                                                 must give <case>.expected
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
#   tests/conformance/report/<suite>-<case>.expected
#                                                 vigil_precheck_report_dump of
#                                                 each validate and effective case
#   tests/conformance/store/<case>.config         secret stores, with the requests
#   tests/conformance/store/<case>.exchange       to answer and the references to
#   tests/conformance/store/<case>.expected       fetch; every request made, and
#                                                 each result
#   tests/conformance/backend/<case>.config       HTTP backends, a batch of
#   tests/conformance/backend/<case>.events       events, and the answers and
#   tests/conformance/backend/<case>.exchange     deliveries; every request
#   tests/conformance/backend/<case>.expected     made, and each result
#
# Exit code: 0 all passed, 1 any failed.

set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")

# shellcheck source=../app/lib/posix/config.sh
. "$root/app/lib/posix/config.sh"
# shellcheck source=../app/lib/posix/validate.sh
. "$root/app/lib/posix/validate.sh"
# shellcheck source=../app/lib/posix/effective.sh
. "$root/app/lib/posix/effective.sh"
# shellcheck source=../app/lib/posix/command.sh
. "$root/app/lib/posix/command.sh"
# shellcheck source=../app/lib/posix/schedule.sh
. "$root/app/lib/posix/schedule.sh"
# shellcheck source=../app/lib/posix/outcome.sh
. "$root/app/lib/posix/outcome.sh"
# shellcheck source=../app/lib/posix/metrics.sh
. "$root/app/lib/posix/metrics.sh"
# shellcheck source=../app/lib/posix/events.sh
. "$root/app/lib/posix/events.sh"
# shellcheck source=../app/lib/posix/recovery.sh
. "$root/app/lib/posix/recovery.sh"
# shellcheck source=../app/lib/posix/prom.sh
. "$root/app/lib/posix/prom.sh"
# shellcheck source=../app/lib/posix/secrets.sh
. "$root/app/lib/posix/secrets.sh"
# shellcheck source=../app/lib/posix/stores.sh
. "$root/app/lib/posix/stores.sh"
# shellcheck source=../app/lib/posix/worker.sh
. "$root/app/lib/posix/worker.sh"
# shellcheck source=../app/lib/posix/backends.sh
. "$root/app/lib/posix/backends.sh"
# shellcheck source=../app/lib/posix/precheck.sh
. "$root/app/lib/posix/precheck.sh"

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

# A seven-column table without comments or blank lines, single-spaced. A
# function, not inline: bash 3.2 cannot parse a case inside $(...).
table_rows7() {
    local a b c d e f g
    while read -r a b c d e f g || [ -n "$a" ]; do
        case $a in '' | '#'*) continue ;; esac
        printf '%s %s %s %s %s %s %s\n' "$a" "$b" "$c" "$d" "$e" "$f" "$g"
    done < "$1"
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

# The report vigil precheck prints, for every validate and effective case:
# tests/conformance/report/<suite>-<case>.expected holds
# vigil_precheck_report_dump.
for cfg in "$here"/conformance/validate/*.config "$here"/conformance/effective/*.config; do
    suite=$(basename "$(dirname "$cfg")")
    name="$suite-$(basename "$cfg" .config)"
    actual=$(vigil_config_parse "$cfg"; vigil_config_validate; vigil_precheck_report_dump)
    compare "report/$name" "$(cat "$here/conformance/report/$name.expected")" "$actual"
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
    expected=$(table_rows7 "$table")
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

# File backend: <case>.prom (the file before, may be empty) merged with
# <case>.events must give <case>.expected.
for old in "$here"/conformance/prom/*.prom; do
    name=$(basename "$old" .prom)
    compare "prom/$name" "$(cat "${old%.prom}.expected")" "$(vigil_prom_merge "$old" "${old%.prom}.events")"
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


# Secret stores: tests/conformance/store/<case>.config defines the stores and
# <case>.exchange lists, in order: "env NAME value" and "unenv NAME";
# "reply <status> <body>" or "fail <kind>", the answers to the next requests;
# "fetch <reference>", resolved with the requests it makes shown; "json
# <a.b.c> <document>"; "now <amz date>", the time AWS requests are signed
# at; "sigv4 <secret> <key id> <amz date> <region> <service> <method> <path>
# <header>...", one signature of an empty payload; "epoch <seconds>", the
# time GCP sign-ins are made at; "cli <name>...", the vendor CLIs installed
# from then on (none at first), each run answered by the next reply, its
# status the exit code ("fail timeout": stopped). The output must be
# <case>.expected. No request leaves the machine and no CLI runs:
# _vigil_http_send, _vigil_cli_found and _vigil_cli_run are replaced. A case
# named -unix is not run by Git Bash or Cygwin (spec 6.5.3).
_st_replies=()
_st_next=0
_st_clis=' '
_vigil_cli_found() {
    case $_st_clis in *" $1 "*) return 0 ;; esac
    return 1
}
_vigil_cli_run() {
    local t=$1 e r
    shift
    printf '> %s (%ss)\n' "$*" "$t"
    for e in ${_vc_env[@]+"${_vc_env[@]}"}; do printf '>   %s\n' "$e"; done
    _vc_out=''
    _vc_rc=1
    _vc_stopped=0
    [ "$_st_next" -lt "${#_st_replies[@]}" ] || return 0
    r=${_st_replies[$_st_next]}
    _st_next=$((_st_next + 1))
    case $r in
        '!'*) _vc_rc=143; _vc_stopped=1 ;;
        *) _vc_rc=${r%% *}; _vc_out=${r#* } ;;
    esac
}
_st_now=20260101T000000Z
_st_epoch=1767225600
_vigil_gcp_epoch() {
    _vg_epoch=$_st_epoch
}
_vigil_aws_now() {
    _va_now=$_st_now
}
_vigil_http_send() {
    local h r
    printf '> %s %s (%ss%s%s)\n' "$2" "$3" "$1" "${4:+, ca_file $4}" "$([ "$5" = 1 ] && printf ', metadata')"
    for h in ${_vh_headers[@]+"${_vh_headers[@]}"}; do printf '>   %s\n' "$h"; done
    [ "$2" = POST ] && printf '>   %s\n' "$_vh_body"
    _vh_status=''
    _vh_resp=''
    if [ "$_st_next" -ge "${#_st_replies[@]}" ]; then
        _vh_fail=connect
        return 1
    fi
    r=${_st_replies[$_st_next]}
    _st_next=$((_st_next + 1))
    case $r in
        '!'*) _vh_fail=${r#!}; return 1 ;;
    esac
    _vh_status=${r%% *}
    _vh_resp=${r#* }
}
store_case_dump() {
    local line word rest path
    local -a keys
    vigil_config_parse "$1"
    while IFS= read -r line || [ -n "$line" ]; do
        case $line in '' | '#'*) continue ;; esac
        word=${line%% *}
        rest=${line#* }
        case $word in
            env) export "${rest%% *}=${rest#* }" ;;
            unenv) unset "$rest" ;;
            reply) _st_replies[${#_st_replies[@]}]=$rest ;;
            fail) _st_replies[${#_st_replies[@]}]="!$rest" ;;
            fetch)
                printf 'fetch %s\n' "$rest"
                if vigil_secret_resolve /opt/vigil "$rest"; then
                    printf '= %s\n' "$VIGIL_SECRET_VALUE"
                else
                    printf '! %s\n' "$VIGIL_SECRET_WHY"
                fi
                ;;
            json)
                path=${rest%% *}
                IFS=. read -r -a keys <<< "$path"
                printf 'json %s\n' "$path"
                if vigil_json_get "${rest#* }" "${keys[@]}"; then
                    printf '= %s\n' "$VIGIL_JSON_VALUE"
                else
                    printf '! %s\n' "$VIGIL_JSON_WHY"
                fi
                ;;
            now) _st_now=$rest ;;
            epoch) _st_epoch=$rest ;;
            cli) _st_clis=" $rest " ;;
            sigv4)
                read -r -a keys <<< "$rest"
                _va_headers=("${keys[@]:7}")
                printf 'sigv4 %s\n' "${keys[2]}"
                vigil_aws_sign "${keys[0]}" "${keys[1]}" "${keys[2]}" "${keys[3]}" "${keys[4]}" "${keys[5]}" "${keys[6]}" ''
                printf '= %s\n' "$VIGIL_AWS_AUTH"
                ;;
        esac
    done < "${1%.config}.exchange"
    [ "$_st_next" -eq "${#_st_replies[@]}" ] || printf 'unused replies: %d\n' $((${#_st_replies[@]} - _st_next))
}
for cfg in "$here"/conformance/store/*.config; do
    name=$(basename "$cfg" .config)
    case $name:$(uname -s) in
        *-unix:MINGW* | *-unix:MSYS* | *-unix:CYGWIN*) printf '  SKIP  store/%s\n' "$name"; continue ;;
    esac
    compare "store/$name" "$(cat "${cfg%.config}.expected")" "$(store_case_dump "$cfg")"
done

# HTTP backends: tests/conformance/backend/<case>.config defines backends and
# <case>.exchange lists, in order: "env NAME value" and "unenv NAME"; "now
# <epoch>", the time requests are made at; "reply <status> <body>" or "fail
# <kind>", the answers to the next requests; "send <backend>", which delivers
# <case>.events to that backend, with the request it makes shown and what
# became of the batch. The output must be <case>.expected. The replacement
# _vigil_http_send of the store cases answers; no request leaves the machine.
_bk_now=0
_vigil_backend_now() {
    _vb_now=$_bk_now
}
backend_case_dump() {
    local line word rest d
    vigil_config_parse "$1"
    while IFS= read -r line || [ -n "$line" ]; do
        case $line in '' | '#'*) continue ;; esac
        word=${line%% *}
        rest=${line#* }
        case $word in
            env) export "${rest%% *}=${rest#* }" ;;
            unenv) unset "$rest" ;;
            now) _bk_now=$rest ;;
            reply) _st_replies[${#_st_replies[@]}]=$rest ;;
            fail) _st_replies[${#_st_replies[@]}]="!$rest" ;;
            send)
                printf 'send %s\n' "$rest"
                _vigil_wk_get "backend.$rest" type "$rest"
                if vigil_backend_send /opt/vigil "$rest" "$_vw_value" "${1%.config}.events"; then
                    printf '= sent %s\n' "$_vb_sent"
                    while read -r d; do
                        [ -n "$d" ] && printf 'dropped %s\n' "$d"
                    done <<EOT
$_vb_drops
EOT
                else
                    printf '! %s\n' "$_vb_why"
                fi
                ;;
        esac
    done < "${1%.config}.exchange"
    [ "$_st_next" -eq "${#_st_replies[@]}" ] || printf 'unused replies: %d\n' $((${#_st_replies[@]} - _st_next))
}
for cfg in "$here"/conformance/backend/*.config; do
    compare "backend/$(basename "$cfg" .config)" "$(cat "${cfg%.config}.expected")" "$(backend_case_dump "$cfg")"
done

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
