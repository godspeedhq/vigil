# shellcheck shell=bash
#
# Vigil worker - bash 3.2 compatible.
#
# Runs one job once, end to end (SPECIFICATION.md 4.3): claims its launch
# record, records its state, runs the job through its runner, captures its
# output to the job log, classifies the outcome, writes the run's events to
# the spool, writes the final state and releases its run token.
#
#   vigil_launch <root> <job id>
#     Writes a launch record for a new run, as the supervisor does before it
#     starts a worker. Sets VIGIL_RUN_ID.
#   vigil_worker <root> <job id> <run id>
#     Returns the outcome as an exit code: 0 succeeded, 1 warning, 2 failed,
#     3 unknown, and 4 when the launch was abandoned or the configuration
#     could not be read (the job did not run).
#
# Linux and macOS only; Worker.ps1 is the Windows worker. The run token is
# held on file descriptor 9 for the worker's whole life (11.2).
#
# Requires config.sh, validate.sh, effective.sh, command.sh, outcome.sh,
# metrics.sh and events.sh.

# Single-line, at most 500 characters (12.2). Result in _vw_value.
_vigil_wk_clean() {
    local v=$1
    v=${v//$'\r'/ }
    v=${v//$'\n'/ }
    _vw_value=${v:0:500}
}

# Atomically writes the [state] file $1 from "key value" pairs in
# _vw_state[i] (12.3): a temporary file in the same directory, then rename.
_vigil_wk_write_state() {
    local path=$1 tmp="$1.tmp.$$" i pair
    {
        printf '[state]\n'
        i=0
        while [ "$i" -lt "${#_vw_state[@]}" ]; do
            pair=${_vw_state[$i]}
            _vigil_wk_clean "${pair#* }"
            printf '%-16s = %s\n' "${pair%% *}" "$_vw_value"
            i=$((i + 1))
        done
    } > "$tmp" && mv -f "$tmp" "$path"
}

_vigil_wk_set() {
    local i=0
    while [ "$i" -lt "${#_vw_state[@]}" ]; do
        if [ "${_vw_state[$i]%% *}" = "$1" ]; then
            _vw_state[$i]="$1 $2"
            return
        fi
        i=$((i + 1))
    done
    _vw_state[${#_vw_state[@]}]="$1 $2"
}

# The current time as "<epoch> <ISO 8601 UTC>", read once so both agree.
_vigil_wk_now() {
    set -- $(date -u '+%s %Y-%m-%dT%H:%M:%SZ')
    _vw_epoch=$1
    _vw_iso=$2
}

# This system's boot id (11.1). Result in _vw_boot.
_vigil_wk_boot_id() {
    local s
    _vw_boot=''
    if [ -r /proc/sys/kernel/random/boot_id ]; then
        read -r _vw_boot < /proc/sys/kernel/random/boot_id
    else
        # macOS: "{ sec = 1793300000, usec = 12345 } ..."
        s=$(sysctl -n kern.boottime 2>/dev/null)
        s=${s#*sec = }
        s=${s%%,*}
        case $s in *[!0-9]* | '') ;; *) _vw_boot="boot-$s" ;; esac
    fi
}

# Start time of process $1 as epoch seconds, where the platform gives it
# cheaply (Linux); empty elsewhere (12.2). Result in _vw_start.
_vigil_wk_start_time() {
    local stat ticks btime hz line
    _vw_start=''
    [ -r "/proc/$1/stat" ] || return 0
    read -r stat < "/proc/$1/stat" || return 0
    # Fields after the command name, which is in parentheses and may hold spaces.
    stat=${stat##*) }
    set -f
    # shellcheck disable=SC2086
    set -- $stat
    set +f
    ticks=${20}
    btime=''
    while read -r line; do
        case $line in btime\ *) btime=${line#btime } ;; esac
    done < /proc/stat
    hz=$(getconf CLK_TCK 2>/dev/null)
    if [ -n "$btime" ] && [ -n "$hz" ] && [ "$hz" -gt 0 ]; then
        _vw_start=$((btime + ticks / hz))
    fi
}

# Host name, short and lower case, and os (14.6). Sets _vw_host, _vw_os.
_vigil_wk_host() {
    _vw_host=$(uname -n)
    _vw_host=${_vw_host%%.*}
    _vw_host=$(printf '%s' "$_vw_host" | tr ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz)
    case $(uname -s) in
        Darwin) _vw_os=macos ;;
        *) _vw_os=linux ;;
    esac
}

# The first value of key $2 in section $1, or $3. Result in _vw_value.
_vigil_wk_get() {
    local i end
    _vw_value=$3
    vigil_config_section "$1"
    [ "$VIGIL_CFG_SEC" -ge 0 ] || return 0
    i=${VIGIL_CFG_SEC_FIRST[$VIGIL_CFG_SEC]}
    end=$((i + VIGIL_CFG_SEC_COUNT[VIGIL_CFG_SEC]))
    while [ "$i" -lt "$end" ]; do
        if [ "${VIGIL_CFG_KEY[$i]}" = "$2" ]; then
            _vw_value=${VIGIL_CFG_VALUE[$i]}
            return 0
        fi
        i=$((i + 1))
    done
}

# A directory setting resolved against the install root. Result in _vw_dir.
_vigil_wk_dir() {
    _vigil_wk_get "$1" "$2" "$3"
    case $_vw_value in
        /*) _vw_dir=$_vw_value ;;
        *) _vw_dir="$_vw_root/$_vw_value" ;;
    esac
}

# Appends lines to the job's daily log. Each argument is one line.
_vigil_wk_log() {
    local line
    for line in "$@"; do
        printf '%s %s\n' "$_vw_iso" "$line"
    done >> "$_vw_log" 2>/dev/null
}

# Loads and validates the configuration and resolves the directories.
# Returns 1, with a message in _vw_error, when the job cannot be run.
_vigil_wk_config() {
    local i
    _vw_error=''
    if ! vigil_config_parse "$_vw_root/config/vigil.config"; then
        _vw_error='the configuration has errors; run vigil precheck'
        return 1
    fi
    if ! vigil_config_validate; then
        _vw_error='the configuration has errors; run vigil precheck'
        return 1
    fi
    _vigil_wk_get vigil config_source ''
    if [ -n "$_vw_value" ]; then
        _vw_error='remote configuration needs the fetcher, which is not available yet'
        return 1
    fi
    vigil_config_section "job.$_vw_job"
    if [ "$VIGIL_CFG_SEC" -lt 0 ]; then
        case $_vw_job in
            vigil_sender) ;;
            *)
                _vw_error="no job '$_vw_job' in the configuration"
                return 1
                ;;
        esac
    fi
    i=0
    while [ "$i" -lt "${#VIGIL_VAL_KIND[@]}" ]; do
        if [ "${VIGIL_VAL_KIND[$i]}" = INVALID ] && [ "${VIGIL_VAL_JOB[$i]}" = "$_vw_job" ]; then
            _vw_error="job '$_vw_job' is invalid: ${VIGIL_VAL_MSG[$i]}"
            return 1
        fi
        i=$((i + 1))
    done
    _vigil_wk_dir vigil state_dir state
    _vw_statedir=$_vw_dir
    _vigil_wk_dir log dir logs
    _vw_logdir=$_vw_dir
    _vigil_wk_dir spool dir spool
    _vw_spooldir=$_vw_dir
    return 0
}

vigil_launch() {
    _vw_root=$1
    _vw_job=$2
    local LC_ALL=C
    _vigil_wk_config || { printf 'vigil: %s\n' "$_vw_error" >&2; return 4; }
    _vigil_wk_now
    _vigil_wk_boot_id
    VIGIL_RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
    mkdir -p "$_vw_statedir/locks" || return 4
    {
        printf '[launch]\n'
        printf 'job           = %s\n' "$_vw_job"
        printf 'run_id        = %s\n' "$VIGIL_RUN_ID"
        printf 'boot_id       = %s\n' "$_vw_boot"
        printf 'launch_epoch  = %s\n' "$_vw_epoch"
        printf 'launch_at     = %s\n' "$_vw_iso"
    } > "$_vw_statedir/locks/$_vw_job.$VIGIL_RUN_ID.launch.tmp.$$" &&
        mv -f "$_vw_statedir/locks/$_vw_job.$VIGIL_RUN_ID.launch.tmp.$$" "$_vw_statedir/locks/$_vw_job.$VIGIL_RUN_ID.launch"
}

# Runs one of Vigil's own workers, already claimed: running state, the
# function $4 (which returns 0 on success and may set _vw_reason), final
# state, then the token released. Returns 0 succeeded or 2 failed.
_vigil_wk_internal() {
    local rid=$1 token=$2 started=$3 status=succeeded
    _vw_state=()
    _vigil_wk_set schema_version 1
    _vigil_wk_set job "$_vw_job"
    _vigil_wk_set run_id "$rid"
    _vigil_wk_set status running
    _vigil_wk_set reason ''
    _vigil_wk_set boot_id "$_vw_boot"
    _vigil_wk_set started_epoch "$started"
    _vigil_wk_set started_at "$_vw_iso"
    _vigil_wk_set worker_pid $$
    _vigil_wk_set worker_name bash
    _vigil_wk_set worker_start "$_vw_start"
    _vigil_wk_write_state "$_vw_statedir/jobs/$_vw_job.state"
    _vigil_wk_log "$rid run start"
    _vw_reason=''
    "$4" || status=failed
    _vigil_wk_now
    _vigil_wk_set status "$status"
    _vigil_wk_set reason "$_vw_reason"
    _vigil_wk_set ended_epoch "$_vw_epoch"
    _vigil_wk_set ended_at "$_vw_iso"
    _vigil_wk_set duration_seconds $((_vw_epoch - started))
    _vigil_wk_write_state "$_vw_statedir/jobs/$_vw_job.state"
    if [ -n "$_vw_reason" ]; then
        _vigil_wk_log "$rid run end $status ($_vw_reason) in $((_vw_epoch - started))s"
    else
        _vigil_wk_log "$rid run end $status in $((_vw_epoch - started))s"
    fi
    exec 9<&-
    rm -f "$token"
    VIGIL_RUN_OUTCOME=$status
    VIGIL_RUN_REASON=$_vw_reason
    VIGIL_RUN_DURATION=$((_vw_epoch - started))
    [ "$status" = succeeded ] && return 0
    return 2
}

vigil_worker() {
    _vw_root=$1
    _vw_job=$2
    local rid=$3 launch token code=- outcome=failed reason='' rc mode exit_codes
    local i key value missing='' prog pid started duration out err stem spool
    local LC_ALL=C
    _vw_state=()

    _vigil_wk_config || { printf 'vigil: %s\n' "$_vw_error" >&2; return 4; }
    launch="$_vw_statedir/locks/$_vw_job.$rid.launch"
    token="$_vw_statedir/locks/$_vw_job.$rid.token"

    # Claim (11.2): open the launch record, then rename it to the token. The
    # descriptor follows the file, so the token is held without a gap. If the
    # supervisor abandoned the launch first, either step fails and the job
    # does not run.
    if ! exec 9< "$launch"; then
        printf 'vigil: launch %s of %s was abandoned; not running\n' "$rid" "$_vw_job" >&2
        return 4
    fi 2>/dev/null
    if ! mv "$launch" "$token" 2>/dev/null; then
        exec 9<&-
        printf 'vigil: launch %s of %s was abandoned; not running\n' "$rid" "$_vw_job" >&2
        return 4
    fi

    mkdir -p "$_vw_statedir/jobs" "$_vw_logdir/jobs/$_vw_job" "$_vw_spooldir/incoming"
    _vw_log="$_vw_logdir/jobs/$_vw_job/$(date '+%Y-%m-%d').log"
    _vigil_wk_host
    _vigil_wk_boot_id
    _vigil_wk_start_time $$
    _vigil_wk_now
    started=$_vw_epoch

    # Vigil's own workers run a function, not a job command (4.5).
    case $_vw_job in
        vigil_sender)
            _vigil_wk_internal "$rid" "$token" "$started" vigil_send
            return $?
            ;;
    esac

    vigil_config_effective "$_vw_job"
    exit_codes=standard
    i=0
    while [ "$i" -lt "${#VIGIL_EFF_KEY[@]}" ]; do
        key=${VIGIL_EFF_KEY[$i]}
        value=${VIGIL_EFF_VALUE[$i]}
        case $key in
            exit_codes) exit_codes=$value ;;
            require_env)
                if ! eval "[ -n \"\${$value+set}\" ]"; then
                    missing="$missing $value"
                fi
                ;;
        esac
        i=$((i + 1))
    done
    mode=standard
    [ "$exit_codes" = nagios ] && mode=nagios

    _vigil_wk_set schema_version 1
    _vigil_wk_set job "$_vw_job"
    _vigil_wk_set run_id "$rid"
    _vigil_wk_get vigil instance vigil
    _vigil_wk_set instance "$_vw_value"
    _vigil_wk_set status running
    _vigil_wk_set reason ''
    _vigil_wk_set boot_id "$_vw_boot"
    _vigil_wk_set started_epoch "$started"
    _vigil_wk_set started_at "$_vw_iso"
    _vigil_wk_set worker_pid $$
    _vigil_wk_set worker_name bash
    _vigil_wk_set worker_start "$_vw_start"
    _vigil_wk_write_state "$_vw_statedir/jobs/$_vw_job.state"
    _vigil_wk_log "$rid run start"

    out="$_vw_logdir/jobs/$_vw_job/$rid.out"
    err="$_vw_logdir/jobs/$_vw_job/$rid.err"
    : > "$out"
    : > "$err"

    vigil_job_command "$_vw_job" posix "$_vw_root"
    prog=$VIGIL_CMD_PROGRAM
    if [ -n "$VIGIL_CMD_ERROR" ]; then
        reason=$VIGIL_CMD_MESSAGE
    elif [ -n "$missing" ]; then
        reason="missing environment variable${missing}"
    elif [ ! -d "$VIGIL_CMD_CWD" ]; then
        reason="working directory not found: $VIGIL_CMD_CWD"
    else
        case $prog in
            */*)
                if [ ! -e "$prog" ]; then reason="not found: $prog"
                elif [ ! -x "$prog" ] || [ -d "$prog" ]; then reason="not executable: $prog"
                fi
                ;;
            *) command -v "$prog" > /dev/null 2>&1 || reason="not found: $prog" ;;
        esac
        # The job's own file must exist too, whatever runs it.
        _vigil_wk_get "job.$_vw_job" file ''
        _vigil_cmd_path "$_vw_value" posix "$_vw_root"
        if [ -z "$reason" ] && [ ! -f "$_vc_path" ]; then
            reason="file not found: $_vc_path"
        fi
    fi

    if [ -z "$reason" ]; then
        # Run the job in its own process group (10.3), with its environment,
        # never through a shell. The job inherits the run token on fd 9.
        set -m
        (
            cd "$VIGIL_CMD_CWD" || exit 126
            export VIGIL_RUN_ID="$rid"
            i=0
            while [ "$i" -lt "${#VIGIL_EFF_KEY[@]}" ]; do
                if [ "${VIGIL_EFF_KEY[$i]}" = env ]; then
                    export "${VIGIL_EFF_VALUE[$i]%%=*}=${VIGIL_EFF_VALUE[$i]#*=}"
                fi
                i=$((i + 1))
            done
            exec "$prog" ${VIGIL_CMD_ARGS[@]+"${VIGIL_CMD_ARGS[@]}"}
        ) > "$out" 2> "$err" < /dev/null &
        pid=$!
        _vigil_wk_set job_pid "$pid"
        _vigil_wk_set job_name "${prog##*/}"
        _vigil_wk_start_time "$pid"
        _vigil_wk_set job_start "$_vw_start"
        _vigil_wk_write_state "$_vw_statedir/jobs/$_vw_job.state"
        wait "$pid"
        code=$?
        set +m
        vigil_outcome "$exit_codes" "$code"
        outcome=$VIGIL_OUTCOME
        case $outcome in
            succeeded) reason='' ;;
            *) reason="exit code $code" ;;
        esac
    fi

    _vigil_wk_now
    duration=$((_vw_epoch - started))

    # The job log (13.1): its output, then how it ended.
    while IFS= read -r value || [ -n "$value" ]; do
        printf '%s %s out %s\n' "$_vw_iso" "$rid" "${value%$'\r'}"
    done < "$out" >> "$_vw_log"
    while IFS= read -r value || [ -n "$value" ]; do
        printf '%s %s err %s\n' "$_vw_iso" "$rid" "${value%$'\r'}"
    done < "$err" >> "$_vw_log"

    vigil_metrics_parse "$mode" "$VIGIL_METRIC_LINES_MAX" "$out"
    vigil_run_events "$_vw_job" "$_vw_epoch" "$outcome" "$code" "$duration" "$_vw_host" "$_vw_os"

    # Events before the final state (4.3, step 7).
    stem="$_vw_epoch-$_vw_job-$rid.events"
    spool="$_vw_spooldir/incoming/$stem"
    vigil_run_events_dump > "$spool.tmp.$$" && mv -f "$spool.tmp.$$" "$spool"

    _vigil_wk_set status "$outcome"
    _vigil_wk_set reason "$reason"
    _vigil_wk_set ended_epoch "$_vw_epoch"
    _vigil_wk_set ended_at "$_vw_iso"
    _vigil_wk_set duration_seconds "$duration"
    _vigil_wk_set exit_code "${code#-}"
    _vigil_wk_set metric_lines "$VIGIL_MET_LINES"
    _vigil_wk_set invalid_lines "$VIGIL_MET_INVALID"
    _vigil_wk_set dropped_lines "$VIGIL_MET_DROPPED"
    _vigil_wk_set spool_file "$stem"
    _vigil_wk_write_state "$_vw_statedir/jobs/$_vw_job.state"
    if [ -n "$reason" ]; then
        _vigil_wk_log "$rid run end $outcome ($reason) in ${duration}s"
    else
        _vigil_wk_log "$rid run end $outcome in ${duration}s"
    fi
    rm -f "$out" "$err"

    # Release the token: close it, then delete it (4.3, step 9).
    exec 9<&-
    rm -f "$token"

    VIGIL_RUN_OUTCOME=$outcome
    VIGIL_RUN_REASON=$reason
    VIGIL_RUN_DURATION=$duration

    case $outcome in
        succeeded) rc=0 ;;
        warning) rc=1 ;;
        unknown) rc=3 ;;
        *) rc=2 ;;
    esac
    return "$rc"
}
