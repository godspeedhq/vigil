# shellcheck shell=bash
#
# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# Vigil doctor - bash 3.2 compatible.
#
# What vigil doctor prints (SPECIFICATION.md 16.7): how well Vigil runs on
# this machine. Reads only; changes and fixes nothing. The twin of
# Doctor.ps1, without its Windows section.
#
#   vigil_doctor <root>
#     Prints the report. Returns 1 when any line is WARN, else 0.
#   vigil_doctor_open <root> <temporary file>
#     The files and folders Vigil runs or reads its jobs from that others
#     than their owner may write: _dr_open, and _dr_hidden, the folders
#     this account could not look into.
#   vigil_doctor_runs_since <job log dir> <ISO 8601 UTC>
#     The runs a job log records as ended since then: _dr_runs, of them
#     _dr_measured with their CPU, summed in _dr_sum, and their time in
#     _dr_time (seconds); _dr_unreadable, the log files that could not be
#     read, one per line.
#
# Requires config.sh, worker.sh, command.sh and fetch.sh.

VIGIL_DOCTOR_SHELLS=' bash sh dash zsh ksh '

# Who may change what Vigil runs (16.7): the root's own folder, and app/,
# vendor/, packs/, scripts/ and config/ with all they hold, writable by
# others than their owner. A group named as its owner (a user private
# group, as Fedora makes) is the owner's. Into _dr_open, one
# "<path>: <who>" a line; into _dr_hidden, the folders this account could
# not look into, one a line. $2 is a temporary file.
vigil_doctor_open() {
    local root=$1 tmp=$2 p d
    _dr_open='' _dr_hidden=''
    {
        find "$root" -maxdepth 0 ! -type l \( -perm -020 -o -perm -002 \) -print
        for d in app vendor packs scripts config; do
            [ ! -e "$root/$d" ] || find "$root/$d" ! -type l \( -perm -020 -o -perm -002 \) -print
        done
    } 2> "$tmp" | while IFS= read -r p; do
        # shellcheck disable=SC2046
        set -- $(ls -ld -- "$p" 2> /dev/null)
        [ "$#" -ge 4 ] || continue
        case $1 in
            ????????w*) printf '%s: anyone\n' "$p" ;;
            ?????w*) [ "$4" = "$3" ] || printf '%s: group %s\n' "$p" "$4" ;;
        esac
    done > "$tmp.open"
    _dr_open=$(cat "$tmp.open")
    # GNU find quotes the path (in the C locale, with '), BSD find does not.
    _dr_hidden=$(sed -n -e "s/^find: '\(.*\)': Permission denied\$/\1/p" -e t -e 's/^find: \(.*\): Permission denied$/\1/p' "$tmp")
    rm -f "$tmp.open"
}

vigil_doctor_runs_since() {
    local f g
    _dr_runs=0 _dr_measured=0 _dr_sum=0 _dr_time=0 _dr_unreadable=''
    [ -d "$1" ] || return 0
    # Only the logs written in the last two hours can hold the last hour.
    f=$(find "$1" -name '*.log' -mmin -120 2>/dev/null)
    [ -n "$f" ] || return 0
    # A log it cannot read is not a job with no runs (18.5): named.
    while IFS= read -r g; do
        [ -r "$g" ] || _dr_unreadable="$_dr_unreadable$g
"
    done <<EOF
$f
EOF
    # "<ISO> <run id> run end <outcome> ... in <n>s, cpu <s>s" (13.1): the
    # ISO times compare as text.
    set -- $(printf '%s\n' "$f" | while IFS= read -r f; do cat "$f" 2>/dev/null; done | LC_ALL=C awk -v c="$2" '
        $3 == "run" && $4 == "end" && $1 >= c {
            runs++
            if ($(NF - 1) == "cpu" && $NF ~ /^[0-9]+\.[0-9]+s$/) { measured++; cpu += $NF; time += $(NF - 2) }
            else time += $NF
        }
        END { printf "%d %d %.2f %d\n", runs, measured, cpu, time }')
    _dr_runs=$1 _dr_measured=$2 _dr_sum=$3 _dr_time=$4
}

# The CPU this shell's waited-for children have used, in milliseconds, in
# _dr_ms: the second line of bash's times, read through the file $1 (in a
# $(...) subshell it would be the subshell's).
_vigil_dr_children_ms() {
    local t f m s ms=0
    times > "$1" 2>/dev/null || { _dr_ms=0; return; }
    t=$(sed -n 2p "$1")
    for f in $t; do
        f=${f%s}
        m=${f%%m*}
        s=${f#*m}
        s=${s/,/.}
        case $s in *.*) ;; *) s="$s.000" ;; esac
        f=${s#*.}000
        s=${s%%.*}
        ms=$((ms + 10#$m * 60000 + 10#$s * 1000 + 10#${f:0:3}))
    done
    _dr_ms=$ms
}

# Microseconds since the epoch in _dr_us, when bash can say (5.0 and
# later); empty otherwise.
_vigil_dr_clock() {
    _dr_us=''
    [ -n "${EPOCHREALTIME-}" ] || return 0
    local t=${EPOCHREALTIME/,/.}
    _dr_us=$(( ${t%.*} * 1000000 + 10#${t#*.} ))
}

# Three bare starts of the shell $1: the median CPU and wall time, in
# milliseconds, in _dr_cpu and _dr_wall (empty when the clock is not
# available). $2 is a temporary file.
_vigil_dr_shell() {
    local i before cpus='' walls='' start
    for i in 1 2 3; do
        _vigil_dr_children_ms "$2"; before=$_dr_ms
        _vigil_dr_clock; start=$_dr_us
        "$1" -c exit > /dev/null 2>&1 < /dev/null
        _vigil_dr_clock
        [ -n "$start" ] && [ -n "$_dr_us" ] && walls="$walls $(((_dr_us - start) / 1000))"
        _vigil_dr_children_ms "$2"
        cpus="$cpus $((_dr_ms - before))"
    done
    _dr_cpu=$(printf '%s\n' $cpus | sort -n | sed -n 2p)
    _dr_wall=''
    [ -n "$walls" ] && _dr_wall=$(printf '%s\n' $walls | sort -n | sed -n 2p)
}

vigil_doctor() {
    local root=$1 statedir logdir joblogs denied configdenied f job since cutoff
    local warn=0 rows='' unreadable='' report tmp shells s i name prog
    local LC_ALL=C
    _vw_root=$root
    _vw_job=-
    f="$root/config/vigil.config"
    # A configuration this account cannot read (a system install, as
    # another account) is never taken for a missing one (18.5): what it
    # cannot read is said, and the checks that need no configuration run.
    if configdenied=$(vigil_denied "$f"); then
        vigil_config_parse /dev/null
    else
        configdenied=''
        vigil_config_parse "$f"
    fi
    # The state directory is always the local file's (6.8).
    _vigil_wk_dir vigil state_dir state; statedir=$_vw_dir
    _vigil_wk_dir log dir logs; logdir=$_vw_dir

    # What each run used (cpu_seconds, 12.2), from the run end lines of the
    # last hour (13.1).
    printf "What Vigil's runs cost in the last hour\n"
    joblogs="$logdir/jobs"
    denied=$configdenied
    if [ -n "$denied" ] || denied=$(vigil_denied "$joblogs"); then
        printf '  WARN  %s\n' "$(vigil_denied_message "$denied")"
        warn=$((warn + 1))
    else
        _vigil_wk_now
        cutoff=$((_vw_epoch - 3600))
        since=$(date -u -d "@$cutoff" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r "$cutoff" '+%Y-%m-%dT%H:%M:%SZ')
        for f in "$joblogs"/*/; do
            [ -d "$f" ] || continue
            job=${f%/}
            job=${job##*/}
            vigil_doctor_runs_since "$joblogs/$job" "$since"
            unreadable="$unreadable$_dr_unreadable"
            [ "$_dr_runs" -gt 0 ] || continue
            rows="$rows$job $_dr_runs $_dr_measured $_dr_sum $_dr_time
"
        done
        if [ -z "$rows" ]; then
            printf '  note  no runs in the last hour\n'
        else
            # Sorted by what each job cost in the hour, most first. awk
            # does the arithmetic: bash has no fractions.
            report=$(printf '%s' "$rows" | sort -k4,4nr -k1,1 | awk '
                BEGIN { printf "  %-24s %6s %10s %10s %10s\n", "job", "runs", "CPU", "CPU/run", "time/run" }
                {
                    cpu = $3 ? sprintf("%.2f s", $4) : "-"
                    per = $3 ? sprintf("%.2f s", $4 / $3) : "-"
                    printf "  %-24s %6d %10s %10s %10s\n", $1, $2, cpu, per, sprintf("%.1f s", $5 / $2)
                    cores += $4 / 3600
                    unknown += $2 - $3
                }
                END {
                    busy = sprintf("Vigil'\''s runs keep %.2f of a core busy", cores)
                    if (cores > 0.5) printf "  WARN  %s, above half of one: the jobs above cost the most\n", busy
                    else if (cores > 0.25) printf "  note  %s, above a quarter of one\n", busy
                    else printf "  ok    %s\n", busy
                    if (unknown) printf "  note  %d run(s) show no CPU: they ended before Vigil recorded it\n", unknown
                }')
            printf '%s\n' "$report"
            case $report in *'  WARN  '*) warn=$((warn + 1)) ;; esac
        fi
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            printf '  WARN  cannot read %s: its runs are not counted above\n' "$f"
            warn=$((warn + 1))
        done <<EOF
$unreadable
EOF
        # Less than an hour of runs is still shown over an hour: said. The
        # supervisor's last start, from its log of today or yesterday (13.1).
        f=$(find "$logdir/supervisor" -name '*.log' -mtime -2 2>/dev/null)
        if [ -n "$f" ]; then
            f=$(printf '%s\n' "$f" | while IFS= read -r s; do cat "$s" 2>/dev/null; done |
                awk '$2 == "INFO" && $3 == "supervisor" && $4 == "supervisor" && $5 == "started," && $1 > last { last = $1 } END { print last }')
            if [ -n "$f" ] && [[ $f > $since ]]; then
                s=$(date -u -d "$f" '+%s' 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$f" '+%s' 2>/dev/null)
                [ -n "$s" ] && printf '  note  the supervisor started %d minute(s) ago: the figures above are those minutes of runs, over a full hour\n' $(((_vw_epoch - s) / 60))
            fi
        fi
    fi

    # How long a bare start of each shell takes: every run starts one.
    printf '\nStarting a shell (median of 3)\n'
    shells=' '
    prog=$(command -v bash 2>/dev/null) && shells=" $prog "
    if [ -z "$configdenied" ] && vigil_fetch_mode && _vigil_wk_get vigil config_source '' && [ -n "$_vw_value" ] &&
        vigil_active_read "$statedir" && [ -f "$VIGIL_ACT_CONFIG" ]; then
        vigil_config_parse "$VIGIL_ACT_CONFIG"
    fi
    i=0
    while [ "$i" -lt "${#VIGIL_CFG_SEC_NAME[@]}" ]; do
        case ${VIGIL_CFG_SEC_NAME[$i]} in
            job.*)
                vigil_job_command "${VIGIL_CFG_SEC_NAME[$i]#job.}" posix "$root" 2>/dev/null
                if [ -z "$VIGIL_CMD_ERROR" ] && [ -n "$VIGIL_CMD_PROGRAM" ]; then
                    name=${VIGIL_CMD_PROGRAM##*/}
                    case $VIGIL_DOCTOR_SHELLS in
                        *" $name "*)
                            prog=$(command -v "$VIGIL_CMD_PROGRAM" 2>/dev/null) &&
                                case $shells in *" $prog "*) ;; *) shells="$shells$prog " ;; esac
                            ;;
                    esac
                fi
                ;;
        esac
        i=$((i + 1))
    done
    tmp=$(mktemp "${TMPDIR:-/tmp}/vigil-doctor.XXXXXX") || tmp=''
    for s in $shells; do
        if [ -z "$tmp" ]; then printf '  note  %s: not measured (no temporary file)\n' "$s"; continue; fi
        _vigil_dr_shell "$s" "$tmp"
        if [ -n "$_dr_wall" ]; then
            f=$(awk -v c="$_dr_cpu" -v w="$_dr_wall" 'BEGIN { printf "%.2f CPU s, %.2f s", c / 1000, w / 1000 }')
            if [ "$_dr_wall" -gt 1000 ]; then
                printf '  WARN  %s: %s, above 1 s: every run starts it\n' "$s" "$f"; warn=$((warn + 1))
            else
                printf '  ok    %s: %s\n' "$s" "$f"
            fi
        else
            f=$(awk -v c="$_dr_cpu" 'BEGIN { printf "%.2f CPU s", c / 1000 }')
            if [ "$_dr_cpu" -gt 1000 ]; then
                printf '  WARN  %s: %s, above 1 s: every run starts it\n' "$s" "$f"; warn=$((warn + 1))
            else
                printf '  ok    %s: %s (this bash has no clock for the wall time)\n' "$s" "$f"
            fi
        fi
    done
    # Who can change what Vigil runs: whoever can write its folders can
    # change what it runs, as the account it runs as.
    printf '\nWho can change what Vigil runs\n'
    if [ -z "$tmp" ]; then
        printf '  note  not checked (no temporary file)\n'
    else
        vigil_doctor_open "$root" "$tmp"
        if [ -n "$_dr_open" ]; then
            i=$(printf '%s\n' "$_dr_open" | wc -l | tr -d ' ')
            printf '  WARN  %d of its files and folders can be written by others than their owner, who can then change what Vigil runs: chmod go-w each\n' "$i"
            warn=$((warn + 1))
            printf '%s\n' "$_dr_open" | head -n 5 | sed 's/^/        /'
            [ "$i" -le 5 ] || printf '        and %d more\n' $((i - 5))
        elif [ -z "$_dr_hidden" ]; then
            printf '  ok    only their owners can change app, vendor, packs, scripts and config\n'
        fi
        printf '%s\n' "$_dr_hidden" | while IFS= read -r f; do
            [ -z "$f" ] || printf '  note  cannot look into %s from this account: run this as the account Vigil runs as to check it\n' "$f"
        done
    fi
    [ -n "$tmp" ] && rm -f "$tmp"

    printf '\n'
    if [ "$warn" -gt 0 ]; then
        printf 'doctor: %d warning(s)\n' "$warn"
        return 1
    fi
    printf 'doctor: no warnings\n'
    return 0
}
