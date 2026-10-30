# shellcheck shell=bash
#
# Vigil supervisor - bash 3.2 compatible.
#
# The long-running tick loop the service manager runs (SPECIFICATION.md
# 4.1). Each tick it reloads the configuration when it changed, accounts
# for every job's latest run (11.3), reaches each job's schedule decision
# (7.9), admits due runs within max_concurrent (8), launches each as a
# detached worker (4.3), and writes jobs.log (13.2) and its own events.
#
#   vigil_supervise <root> <once: 0|1>
#     Returns 1 when another supervisor owns the state directory or the
#     configuration cannot be loaded at startup.
#
# Linux and macOS only; Supervisor.ps1 is the Windows supervisor. The
# supervisor lock is held on file descriptor 8 for its whole life (12.4).
#
# Requires config.sh, validate.sh, effective.sh, command.sh, schedule.sh,
# outcome.sh, metrics.sh, events.sh, recovery.sh and worker.sh.

VIGIL_LAUNCH_GRACE=120

_vigil_sup_log() {
    local level=$1
    shift
    mkdir -p "$_su_logdir/supervisor" 2>/dev/null
    printf '%s %s supervisor %s\n' "$_su_iso" "$level" "$*" >> "$_su_logdir/supervisor/$_su_date.log" 2>/dev/null
}

# Whether a process other than this one holds file $1 open. Sets _su_held to
# yes, no or error (the probe could not be made).
_vigil_sup_held() {
    local f pid out
    _su_held=no
    case $_su_platform in
        linux)
            for f in /proc/[0-9]*/fd/*; do
                if [ "$f" -ef "$1" ]; then
                    pid=${f#/proc/}
                    pid=${pid%%/*}
                    if [ "$pid" != "$$" ]; then _su_held=yes; return 0; fi
                fi
            done 2>/dev/null
            ;;
        macos)
            if ! command -v lsof > /dev/null 2>&1; then _su_held=error; return 0; fi
            out=$(lsof -t -- "$1" 2>/dev/null)
            for pid in $out; do
                if [ "$pid" != "$$" ]; then _su_held=yes; return 0; fi
            done
            ;;
        *) _su_held=error ;;
    esac
}

# Whether a process carries run id $1 on its command line. Sets _su_proc to
# yes, no or error.
_vigil_sup_proc() {
    local d a
    _su_proc=no
    case $_su_platform in
        linux)
            for d in /proc/[0-9]*; do
                [ -r "$d/cmdline" ] || continue
                while IFS= read -r -d '' a; do
                    if [ "$a" = "$1" ]; then _su_proc=yes; return 0; fi
                done < "$d/cmdline"
            done 2>/dev/null
            ;;
        macos)
            if ps -axww -o args= 2>/dev/null | grep -F -e "--run-id $1" > /dev/null; then
                _su_proc=yes
            elif ! ps -p $$ > /dev/null 2>&1; then
                _su_proc=error
            fi
            ;;
        *) _su_proc=error ;;
    esac
}

# Reads state file $1. Sets _ss (missing, unreadable, running or final),
# _ss_status, _ss_run_id, _ss_boot and _ss_started.
_vigil_sup_read_state() {
    local line key value header=0
    _ss=missing _ss_status='' _ss_run_id='' _ss_boot='' _ss_started=''
    [ -e "$1" ] || return 0
    _ss=unreadable
    [ -r "$1" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%$'\r'}
        case $line in
            '[state]') header=1; continue ;;
            *' = '* | *' =') ;;
            *) continue ;;
        esac
        key=${line%%=*}
        key=${key%"${key##*[! ]}"}
        value=${line#*=}
        value=${value# }
        case $key in
            schema_version) [ "$value" = 1 ] || return 0 ;;
            status) _ss_status=$value ;;
            run_id) _ss_run_id=$value ;;
            boot_id) _ss_boot=$value ;;
            started_epoch) _ss_started=$value ;;
        esac
    done < "$1"
    [ "$header" -eq 1 ] || return 0
    case $_ss_status in
        running) _ss=running ;;
        succeeded | warning | failed | unknown | timed_out | crashed) _ss=final ;;
    esac
}

# The outcome recorded in a run's spool file, if one exists. Sets _su_spool
# (yes or no), _su_spool_outcome and _su_spool_file.
_vigil_sup_spool() {
    local f name rest
    _su_spool=no _su_spool_outcome='' _su_spool_file=''
    for f in "$_su_spooldir"/incoming/*-"$1"-"$2".events "$_su_spooldir"/backends/*/*-"$1"-"$2".events; do
        [ -f "$f" ] || continue
        while read -r rest name rest; do
            case $name in
                *.succeeded) _su_spool_outcome=succeeded ;;
                *.warnings) _su_spool_outcome=warning ;;
                *.failures) _su_spool_outcome=failed ;;
            esac
        done < "$f"
        if [ -n "$_su_spool_outcome" ]; then
            _su_spool=yes
            _su_spool_file=${f##*/}
            return 0
        fi
    done
}

# Records a concluded run whose worker can no longer write (12.3, VIGIL-005):
# finished (from its spool file) or crashed. Quarantines an unreadable state
# file first.
_vigil_sup_record() {
    local job=$1 rid=$2 conclusion=$3 path="$_su_statedir/jobs/$1.state"
    if [ "$_ss" = unreadable ]; then
        mkdir -p "$_su_statedir/quarantine"
        mv -f "$path" "$_su_statedir/quarantine/$job.$_su_epoch.state" 2>/dev/null
        _vigil_sup_event "$job" state_corrupt 1 count
        _vigil_sup_log WARN "job $job: unreadable state file quarantined"
    fi
    _vw_state=()
    _vigil_wk_set schema_version 1
    _vigil_wk_set job "$job"
    _vigil_wk_set run_id "$rid"
    _vigil_wk_set instance "$_su_instance"
    if [ "$conclusion" = finished ]; then
        _vigil_wk_set status "$_su_spool_outcome"
        _vigil_wk_set reason 'reconciled from the spool file'
        _vigil_wk_set spool_file "$_su_spool_file"
        _vigil_sup_log INFO "job $job: run $rid finished ($_su_spool_outcome), reconciled from its spool file"
    else
        _vigil_wk_set status crashed
        _vigil_wk_set reason 'worker vanished'
        _vigil_sup_event "$job" crashes 1 count
        _vigil_sup_log WARN "job $job: run $rid crashed: worker vanished without an outcome"
        _su_crashed="$_su_crashed $job"
    fi
    _vigil_wk_set boot_id "$_ss_boot"
    _vigil_wk_set started_epoch "$_ss_started"
    _vigil_wk_set ended_epoch "$_su_epoch"
    mkdir -p "$_su_statedir/jobs"
    _vigil_wk_write_state "$path"
}

# Accounts for job $1's latest run (11.3). Sets _su_active to running when
# a run is alive, launching or uncertain, else -.
_vigil_sup_account() {
    local job=$1 f rid='' launch='' token='' lstate=none tstate=none boot=same epoch lboot proc=-
    _su_active=-
    for f in "$_su_statedir/locks/$job".*.launch; do [ -e "$f" ] && { launch=$f; break; }; done
    for f in "$_su_statedir/locks/$job".*.token; do [ -e "$f" ] && { token=$f; break; }; done
    _vigil_sup_read_state "$_su_statedir/jobs/$job.state"

    if [ -n "$launch" ]; then
        rid=${launch##*/$job.}
        rid=${rid%.launch}
        _vigil_sup_held "$launch"
        if [ "$_su_held" = yes ]; then
            lstate=held
        else
            epoch='' lboot=''
            while IFS= read -r f || [ -n "$f" ]; do
                case $f in
                    'launch_epoch '*) epoch=${f##* } ;;
                    'boot_id '*) lboot=${f##* } ;;
                esac
            done < "$launch"
            if [ -n "$lboot" ] && [ "$lboot" != "$_su_boot" ]; then
                lstate=prevboot
            elif [ -n "$epoch" ] && [ $((_su_epoch - epoch)) -lt "$VIGIL_LAUNCH_GRACE" ]; then
                lstate=young
            else
                lstate=old
                _vigil_sup_proc "$rid"
                proc=$_su_proc
            fi
        fi
    else
        if [ -n "$token" ]; then
            rid=${token##*/$job.}
            rid=${rid%.token}
            _vigil_sup_held "$token"
            case $_su_held in yes) tstate=held ;; no) tstate=free ;; *) tstate=free; proc=error ;; esac
        else
            rid=$_ss_run_id
        fi
        # A readable state of an earlier run says nothing about this one.
        if [ "$_ss" != missing ] && [ "$_ss" != unreadable ] && [ "$_ss_run_id" != "$rid" ]; then
            _ss=missing
        fi
        if [ -n "$_ss_boot" ] && [ "$_ss_boot" != "$_su_boot" ] && [ "$_ss" != missing ]; then
            boot=changed
        fi
        if [ "$proc" = - ] && [ "$tstate" != held ] && [ "$boot" = same ]; then
            if [ "$tstate" != none ] || [ "$_ss" = running ] || [ "$_ss" = unreadable ]; then
                _vigil_sup_proc "$rid"
                proc=$_su_proc
            fi
        fi
    fi

    _vigil_sup_spool "$job" "$rid"
    vigil_recovery_conclude "$lstate" "$tstate" "$proc" "$boot" "$_ss" "$_su_spool"
    case $VIGIL_RECOVERY in
        alive | launching)
            _su_active=running
            ;;
        uncertain)
            _su_active=running
            _su_uncertain="$_su_uncertain $job"
            _vigil_sup_event "$job" uncertain 1 gauge
            ;;
        abandon)
            # Abandon by renaming the launch record: only one of this and the
            # worker's claim can succeed (11.2).
            if mv "$launch" "${launch%.launch}.abandoned" 2>/dev/null; then
                rm -f "${launch%.launch}.abandoned"
                _vigil_sup_event "$job" abandoned_launches 1 count
                _vigil_sup_log WARN "job $job: launch $rid abandoned: its worker never claimed it"
            else
                _su_active=running
            fi
            ;;
        finished | crashed)
            if [ "$_ss" != final ]; then
                [ "$VIGIL_RECOVERY" = finished ] || _su_spool_outcome=''
                _vigil_sup_record "$job" "$rid" "$VIGIL_RECOVERY"
            fi
            [ -n "$token" ] && rm -f "$token"
            ;;
    esac
}

# Queues one event of job $1 (or the supervisor's own when $1 is empty):
# name suffix $2, value $3, type $4.
_vigil_sup_event() {
    local tags=$_su_tags name
    if [ -n "$1" ]; then
        name=$(_vigil_sup_metric "$1").$2
        tags="$tags job=$1"
    else
        name=vigil.supervisor.$2
    fi
    _su_events[${#_su_events[@]}]="$_su_epoch $name $3 $4 $tags"
}

# A job's metric_name (6.6): the key, else the job id.
_vigil_sup_metric() {
    _vigil_wk_get "job.$1" metric_name "$1"
    printf '%s' "$_vw_value"
}

# Loads the configuration when it changed. An invalid configuration is
# rejected and the last valid one, kept in state/config.valid, stays active
# (16.3). Returns 1 when there is no valid configuration at all.
_vigil_sup_config() {
    local sum
    sum=$(cksum < "$_su_root/config/vigil.config" 2>/dev/null)
    [ "$sum" = "${_su_cfgsum-}" ] && return 0
    _su_cfgsum=$sum
    _vw_root=$_su_root
    _vw_job=-
    if vigil_config_parse "$_su_root/config/vigil.config" && vigil_config_validate; then
        _vigil_wk_get vigil config_source ''
        if [ -n "$_vw_value" ]; then
            _su_error='remote configuration needs the fetcher, which is not available yet'
        else
            _su_error=''
        fi
    else
        _su_error='the configuration has errors; run vigil precheck'
    fi
    if [ -n "$_su_error" ]; then
        if [ -f "${_su_valid-}" ]; then
            _vigil_sup_log ERROR "configuration rejected, the last valid one stays active: $_su_error"
            _su_reload_failed=1
            vigil_config_parse "$_su_valid" && vigil_config_validate
            return 0
        fi
        return 1
    fi
    _su_reload_failed=0
    _vigil_wk_dir vigil state_dir state
    _su_statedir=$_vw_dir
    _vigil_wk_dir log dir logs
    _su_logdir=$_vw_dir
    _vigil_wk_dir spool dir spool
    _su_spooldir=$_vw_dir
    _vigil_wk_get vigil instance vigil
    _su_instance=$_vw_value
    _vigil_wk_get vigil max_concurrent 5
    _su_max=$_vw_value
    _vigil_wk_get scheduler max_pending 20
    _su_max_pending=$_vw_value
    _vigil_wk_get scheduler tick 60s
    case $_vw_value in
        *s) _su_tick=${_vw_value%s} ;;
        *m) _su_tick=$((${_vw_value%m} * 60)) ;;
        *h) _su_tick=$((${_vw_value%h} * 3600)) ;;
        *d) _su_tick=$((${_vw_value%d} * 86400)) ;;
    esac
    _su_valid="$_su_statedir/config.valid"
    mkdir -p "$_su_statedir"
    cp "$_su_root/config/vigil.config" "$_su_valid.tmp.$$" && mv -f "$_su_valid.tmp.$$" "$_su_valid"

    # Tags of every supervisor event: host, os, instance, then [tags].
    _su_tags="host=$_vw_host os=$_vw_os instance=$_su_instance"
    local i=0
    vigil_config_section tags
    if [ "$VIGIL_CFG_SEC" -ge 0 ]; then
        i=${VIGIL_CFG_SEC_FIRST[$VIGIL_CFG_SEC]}
        while [ "$i" -lt $((VIGIL_CFG_SEC_FIRST[VIGIL_CFG_SEC] + VIGIL_CFG_SEC_COUNT[VIGIL_CFG_SEC])) ]; do
            _su_tags="$_su_tags ${VIGIL_CFG_KEY[$i]}=${VIGIL_CFG_VALUE[$i]}"
            i=$((i + 1))
        done
    fi
    _vigil_sup_log INFO "configuration loaded"
}

# Whether job $1 is INVALID in the active configuration.
_vigil_sup_invalid() {
    local i=0
    while [ "$i" -lt "${#VIGIL_VAL_KIND[@]}" ]; do
        if [ "${VIGIL_VAL_KIND[$i]}" = INVALID ] && [ "${VIGIL_VAL_JOB[$i]}" = "$1" ]; then
            _su_invalid_msg=${VIGIL_VAL_MSG[$i]}
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

# Starts a launched run as a detached worker: it outlives this process
# (4.3), and nothing ties it to the supervisor's terminal or signals.
_vigil_sup_start() {
    local job=$1 rid
    _su_seq=$((_su_seq + 1))
    rid="$(date -u '+%Y%m%dT%H%M%SZ')-$$-$_su_seq"
    mkdir -p "$_su_statedir/locks"
    {
        printf '[launch]\n'
        printf 'job           = %s\n' "$job"
        printf 'run_id        = %s\n' "$rid"
        printf 'boot_id       = %s\n' "$_su_boot"
        printf 'launch_epoch  = %s\n' "$_su_epoch"
    } > "$_su_statedir/locks/$job.$rid.launch.tmp.$$" &&
        mv -f "$_su_statedir/locks/$job.$rid.launch.tmp.$$" "$_su_statedir/locks/$job.$rid.launch" || return 1
    # The worker must not inherit the supervisor lock (fd 8), or it would
    # keep the lock held after the supervisor exits.
    ( trap '' HUP; exec 8>&-; exec "$BASH" "$_su_app/vigil" --root "$_su_root" worker "$job" --run-id "$rid" ) \
        < /dev/null > /dev/null 2>&1 &
    _su_running=$((_su_running + 1))
    _vigil_sup_log INFO "job $job: run $rid started"
}

_vigil_sup_contains() {
    case " $1 " in *" $2 "*) return 0 ;; esac
    return 1
}

# Removes word $2 from the list in variable $1.
_vigil_sup_remove() {
    local out='' w
    for w in ${!1}; do
        [ "$w" = "$2" ] || out="$out $w"
    done
    printf -v "$1" '%s' "${out# }"
}

_vigil_sup_tick() {
    local s name job cursor cfile active next i
    set -- $(date '+%s %Y-%m-%dT%H:%M:%S%z %Y-%m-%d')
    _su_epoch=$1
    _su_now=$2
    _su_date=$3
    _su_iso=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    _su_events=()
    _su_running=0
    _su_uncertain=''
    _su_crashed=''
    _su_status_running=''
    _su_status_waiting=''
    _su_status_disabled=''
    _su_status_invalid=''
    _su_status_last=''

    _vigil_sup_config

    s=0
    while [ "$s" -lt "${#VIGIL_CFG_SEC_NAME[@]}" ]; do
        name=${VIGIL_CFG_SEC_NAME[$s]}
        s=$((s + 1))
        case $name in job.*) ;; *) continue ;; esac
        job=${name#job.}
        if _vigil_sup_invalid "$job"; then
            _vigil_sup_event "$job" invalid_config 1 gauge
            _su_status_invalid="$_su_status_invalid$job: $_su_invalid_msg"$'\n'
            continue
        fi

        _vigil_sup_account "$job"
        active=$_su_active
        if [ "$active" = running ]; then
            _su_running=$((_su_running + 1))
            _su_status_running="$_su_status_running $job"
            if [ -n "$_ss_started" ] && [ "$_ss" = running ]; then
                _vigil_sup_event "$job" running $((_su_epoch - _ss_started)) gauge
            fi
        else
            # A run held by queue_one is admitted once the active run ends.
            if _vigil_sup_contains "$_su_queued" "$job"; then
                _vigil_sup_remove _su_queued "$job"
                _su_pending="$_su_pending $job"
            fi
            [ "$_ss" = final ] && _su_status_last="$_su_status_last$job: $_ss_status"$'\n'
        fi
        _vigil_sup_contains "$_su_queued" "$job" && active=queued
        _vigil_sup_contains "$_su_pending" "$job" && active=running

        cfile="$_su_statedir/schedule/$job.cursor"
        cursor=-
        [ -f "$cfile" ] && read -r cursor < "$cfile"
        if ! vigil_schedule_decide "$job" "$_su_now" "$_su_prev" "$cursor" "$active" && [ "$cursor" != - ]; then
            # A cursor of the other kind (run_every changed to run_at): new.
            cursor=-
            vigil_schedule_decide "$job" "$_su_now" "$_su_prev" "$cursor" "$active"
        fi
        case $VIGIL_SCHED_DECISION in
            disabled)
                rm -f "$cfile"
                _su_status_disabled="$_su_status_disabled $job"
                continue
                ;;
            error) continue ;;
            missed)
                _vigil_sup_event "$job" missed 1 count
                _vigil_sup_log INFO "job $job: slot $VIGIL_SCHED_SLOT missed"
                ;;
            skip)
                _vigil_sup_event "$job" skipped 1 count
                _vigil_sup_log INFO "job $job: slot $VIGIL_SCHED_SLOT skipped: a run is still active"
                ;;
            run) _su_pending="$_su_pending $job" ;;
            queue) _su_queued="$_su_queued $job" ;;
        esac
        if [ "$VIGIL_SCHED_CURSOR" != "$cursor" ]; then
            mkdir -p "$_su_statedir/schedule"
            printf '%s\n' "$VIGIL_SCHED_CURSOR" > "$cfile.tmp.$$" && mv -f "$cfile.tmp.$$" "$cfile"
        fi
        [ "$VIGIL_SCHED_NEXT" != - ] && _su_status_waiting="$_su_status_waiting$job: next $VIGIL_SCHED_NEXT"$'\n'
    done

    # Admission (8): oldest pending first, within max_concurrent; beyond
    # max_pending, runs are skipped.
    next=''
    for job in $_su_pending; do
        if [ "$_su_running" -lt "$_su_max" ]; then
            _vigil_sup_start "$job"
            _su_status_running="$_su_status_running $job"
        else
            next="$next $job"
        fi
    done
    _su_pending=''
    i=0
    for job in $next; do
        i=$((i + 1))
        if [ "$i" -le "$_su_max_pending" ]; then
            _su_pending="$_su_pending $job"
        else
            _vigil_sup_event "$job" skipped 1 count
            _vigil_sup_log WARN "job $job: skipped: more than $_su_max_pending runs pending"
        fi
    done

    _vigil_sup_event '' up 1 gauge
    _vigil_sup_event '' workers "$_su_running" gauge
    set -- $_su_pending
    _vigil_sup_event '' pending $# gauge
    _vigil_sup_event '' config_reload_failed "$_su_reload_failed" gauge

    # The supervisor's events for this tick (4.5).
    mkdir -p "$_su_spooldir/incoming"
    i="$_su_spooldir/incoming/$_su_epoch-supervisor.events"
    s=0
    while [ "$s" -lt "${#_su_events[@]}" ]; do
        printf '%s\n' "${_su_events[$s]}"
        s=$((s + 1))
    done > "$i.tmp.$$" && mv -f "$i.tmp.$$" "$i"

    _vigil_sup_status
    _su_prev=$_su_now
}

# jobs.log (13.2): rewritten every tick.
_vigil_sup_status() {
    local f="$_su_logdir/supervisor/jobs.log" j
    mkdir -p "$_su_logdir/supervisor"
    {
        printf 'Vigil %s at %s\n' "$_su_instance" "$_su_iso"
        [ "$_su_reload_failed" -eq 1 ] && printf '\nCONFIGURATION REJECTED - the last valid configuration is active\n'
        if [ -n "$_su_uncertain" ]; then
            printf '\nUNCERTAIN\n'
            for j in $_su_uncertain; do printf '  %s\n' "$j"; done
        fi
        if [ -n "$_su_crashed" ]; then
            printf '\nCRASHED\n'
            for j in $_su_crashed; do printf '  %s\n' "$j"; done
        fi
        if [ -n "$_su_status_invalid" ]; then
            printf '\nINVALID\n'
            printf '%s' "$_su_status_invalid" | sed 's/^/  /'
        fi
        if [ -n "$_su_status_running" ]; then
            printf '\nRUNNING\n'
            for j in $_su_status_running; do printf '  %s\n' "$j"; done
        fi
        if [ -n "$_su_pending" ]; then
            printf '\nPENDING\n'
            for j in $_su_pending; do printf '  %s\n' "$j"; done
        fi
        if [ -n "$_su_status_waiting" ]; then
            printf '\nWAITING\n'
            printf '%s' "$_su_status_waiting" | sed 's/^/  /'
        fi
        if [ -n "$_su_status_disabled" ]; then
            printf '\nDISABLED\n'
            for j in $_su_status_disabled; do printf '  %s\n' "$j"; done
        fi
        if [ -n "$_su_status_last" ]; then
            printf '\nLAST RUN\n'
            printf '%s' "$_su_status_last" | sed 's/^/  /'
        fi
    } > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
}

vigil_supervise() {
    local once=$2 deadline now
    local LC_ALL=C
    _su_root=$1
    _su_app=$_su_root/app
    [ -n "${VIGIL_APP-}" ] && _su_app=$VIGIL_APP
    _su_prev=-
    _su_pending=''
    _su_queued=''
    _su_seq=0
    _su_reload_failed=0
    _su_stop=0
    _su_logdir=$_su_root/logs
    _su_iso=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    _su_date=$(date '+%Y-%m-%d')
    case $(uname -s) in
        # Git Bash and Cygwin have a Linux-like /proc; used for development only,
        # since Windows runs the PowerShell supervisor.
        Linux | MINGW* | MSYS* | CYGWIN*) _su_platform=linux ;;
        Darwin) _su_platform=macos ;;
        *) _su_platform=other ;;
    esac
    _vigil_wk_host
    _vigil_wk_boot_id
    _su_boot=$_vw_boot

    if ! _vigil_sup_config; then
        printf 'vigil: %s\n' "$_su_error" >&2
        return 1
    fi

    # One supervisor per state directory (12.4).
    mkdir -p "$_su_statedir"
    if [ -e "$_su_statedir/supervisor.lock" ]; then
        _vigil_sup_held "$_su_statedir/supervisor.lock"
        if [ "$_su_held" = yes ]; then
            printf 'vigil: another supervisor owns %s\n' "$_su_statedir" >&2
            return 1
        fi
    fi
    exec 8> "$_su_statedir/supervisor.lock"
    printf 'pid = %s\nstarted_epoch = %s\n' "$$" "$(date '+%s')" >&8
    _vigil_sup_log INFO "supervisor started, pid $$"

    trap '_su_stop=1' TERM INT
    while :; do
        _vigil_sup_tick
        [ "$once" = 1 ] && break
        [ "$_su_stop" -eq 1 ] && break
        deadline=$((_su_epoch + _su_tick))
        now=$(date '+%s')
        if [ "$deadline" -gt "$now" ]; then
            sleep $((deadline - now)) &
            wait $!
        fi
        [ "$_su_stop" -eq 1 ] && break
    done
    _vigil_sup_log INFO "supervisor stopped; running workers continue"
    exec 8>&-
    return 0
}
