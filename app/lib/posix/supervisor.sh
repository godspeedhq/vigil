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
# outcome.sh, metrics.sh, events.sh, recovery.sh, worker.sh and precheck.sh.

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

# Whether process $1 holds file $2 open: yes, no or error. Result in _su_held.
_vigil_sup_holds() {
    local f out pid
    _su_held=no
    case $_su_platform in
        linux)
            [ -d "/proc/$1/fd" ] || return 0
            for f in /proc/"$1"/fd/*; do
                if [ "$f" -ef "$2" ]; then _su_held=yes; return 0; fi
            done 2>/dev/null
            ;;
        macos)
            if ! command -v lsof > /dev/null 2>&1; then _su_held=error; return 0; fi
            out=$(lsof -t -- "$2" 2>/dev/null)
            for pid in $out; do
                if [ "$pid" = "$1" ]; then _su_held=yes; return 0; fi
            done
            ;;
        *) _su_held=error ;;
    esac
}

# Stops run $2 of job $1, past its deadline (10.3, 11.5, 11.6): only once
# its job process is proven to belong to the run, by holding run token $3.
# TERM goes to the job's process group first, KILL after grace. A marker
# written before the first signal tells the worker its job timed out.
_vigil_sup_timeout() {
    local job=$1 rid=$2 token=$3 marker="$_su_statedir/locks/$1.$2.timeout" term='' line grace=30s i
    if [ -z "$_ss_job_pid" ] || [ -z "$token" ]; then
        _su_held=no
    else
        _vigil_sup_holds "$_ss_job_pid" "$token"
    fi
    # Unproven: the caller holds the run as uncertain.
    [ "$_su_held" = yes ] || return 1
    if [ ! -f "$marker" ]; then
        printf 'term_epoch = %s\n' "$_su_epoch" > "$marker"
        kill -TERM -- "-$_ss_job_pid" 2>/dev/null || kill -TERM "$_ss_job_pid" 2>/dev/null
        _vigil_sup_log WARN "job $job: run $rid passed max_runtime; sent TERM to its job"
        return 0
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        case $line in 'term_epoch = '*) term=${line#*= } ;; esac
    done < "$marker"
    vigil_config_effective "$job"
    i=0
    while [ "$i" -lt "${#VIGIL_EFF_KEY[@]}" ]; do
        [ "${VIGIL_EFF_KEY[$i]}" = grace ] && grace=${VIGIL_EFF_VALUE[$i]}
        i=$((i + 1))
    done
    _vigil_wk_secs "$grace"
    if [ -n "$term" ] && [ $((_su_epoch - term)) -ge "$_vw_secs" ]; then
        kill -KILL -- "-$_ss_job_pid" 2>/dev/null || kill -KILL "$_ss_job_pid" 2>/dev/null
        _vigil_sup_log WARN "job $job: run $rid still running $grace after TERM; sent KILL"
    fi
}

# Whether a process carries run id $1 on its command line. Sets _su_proc to
# yes, no or error.
_vigil_sup_proc() {
    local d a out
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
            # Matched in the shell, not with grep: a grep for the run id would
            # find its own command line.
            if ! out=$(ps -axww -o args= 2>/dev/null); then
                _su_proc=error
                return 0
            fi
            case $out in
                *"--run-id $1"*) _su_proc=yes ;;
            esac
            ;;
        *) _su_proc=error ;;
    esac
}

# Reads state file $1. Sets _ss (missing, unreadable, running or final),
# _ss_status, _ss_run_id, _ss_boot and _ss_started.
_vigil_sup_read_state() {
    local line key value header=0
    _ss=missing _ss_status='' _ss_run_id='' _ss_boot='' _ss_started='' _ss_deadline='' _ss_job_pid=''
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
            deadline_epoch) _ss_deadline=$value ;;
            job_pid) _ss_job_pid=$value ;;
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
    local job=$1 rid=$2 conclusion=$3 why=${4-} path="$_su_statedir/jobs/$1.state"
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
    elif [ -f "$_su_statedir/locks/$job.$rid.timeout" ]; then
        # Stopped for max_runtime, and its worker went too.
        _vigil_wk_set status timed_out
        _vigil_wk_set reason 'stopped after max_runtime; its worker exited without a final state'
        _vigil_sup_event "$job" timeouts 1 count
        _vigil_sup_log WARN "job $job: run $rid timed out"
    else
        _vigil_wk_set status crashed
        _vigil_wk_set reason "${why:-worker vanished}"
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
    local reason='' rec="$_su_statedir/recovery/$job.recovery" hold=0
    if [ "$VIGIL_RECOVERY" = alive ] && [ "$_ss" = running ] && [ -n "$_ss_deadline" ] &&
        [ "$_su_epoch" -ge "$_ss_deadline" ]; then
        if ! _vigil_sup_timeout "$job" "$rid" "$token"; then
            # Never kill what cannot be proven to be the run's (VIGIL-007).
            VIGIL_RECOVERY=uncertain
            reason="past max_runtime, but its job process cannot be proven to be the run's"
        fi
    fi
    if [ "$VIGIL_RECOVERY" = uncertain ] && [ -z "$reason" ]; then
        reason='its liveness cannot be established: a probe failed or the evidence conflicts'
    fi

    # Uncertain runs (11.4): a supervisor-owned recovery record holds the job,
    # survives restarts, and is resolved by the evidence or by vigil resolve.
    _vigil_sup_rec_read "$job"
    if [ "$VIGIL_RECOVERY" = uncertain ]; then
        if [ -n "$_rr_resolved_at" ] && [ "$_rr_run_id" = "$rid" ]; then
            _vigil_sup_resolve "$job" "$rid" "$token"
            return 0
        fi
        _vigil_sup_policy "$job"
        [ "$_rr_run_id" = "$rid" ] || _rr_first=''
        [ -n "$_rr_first" ] || _vigil_sup_log WARN "job $job: run $rid is uncertain ($reason); holding it, killing nothing (on_uncertain = $_su_policy)"
        _vigil_sup_rec_write "$job" "$rid" uncertain "$reason" "$_su_policy"
        _su_uncertain="$_su_uncertain$job: $reason"$'\n'
        _vigil_sup_event "$job" uncertain 1 gauge
        if [ "$_su_policy" = replace ]; then
            _su_replacing="$_su_replacing $job"
        else
            _su_active=running
        fi
        return 0
    fi
    if [ -n "$_rr_run_id" ]; then
        if [ "$_rr_policy" = manual ] && [ -z "$_rr_resolved_at" ]; then
            # The evidence cleared; the run is concluded below, but the job
            # stays held until an operator confirms it (11.4).
            hold=1
        else
            [ -n "$_rr_resolved_at" ] && _vigil_sup_log INFO "job $job: hold on run $_rr_run_id released, resolved by $_rr_resolved_by"
            rm -f "$rec" "$_su_statedir/recovery/$job.resolved"
        fi
    fi

    case $VIGIL_RECOVERY in
        alive | launching)
            _su_active=running
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
            rm -f "$_su_statedir/locks/$job.$rid.timeout"
            ;;
    esac
    if [ "$hold" -eq 1 ]; then
        case $VIGIL_RECOVERY in
            alive | launching) ;;
            *) _vigil_sup_rec_write "$job" "$_rr_run_id" "$VIGIL_RECOVERY" "$_rr_reason" manual ;;
        esac
        _su_active=running
        _su_uncertain="$_su_uncertain$job: run $_rr_run_id $VIGIL_RECOVERY; held until vigil resolve (on_uncertain = manual)"$'\n'
        _vigil_sup_event "$job" uncertain 1 gauge
    fi
}

# Reads job $1's recovery record (11.4) and any resolution vigil resolve
# left beside it. Sets _rr_run_id (empty when there is none), _rr_conclusion,
# _rr_reason, _rr_first, _rr_policy, _rr_resolved_by and _rr_resolved_at.
_vigil_sup_rec_read() {
    local line key value f
    _rr_run_id='' _rr_conclusion='' _rr_reason='' _rr_first='' _rr_policy='' _rr_resolved_by='' _rr_resolved_at=''
    for f in "$_su_statedir/recovery/$1.recovery" "$_su_statedir/recovery/$1.resolved"; do
        [ -f "$f" ] || continue
        while IFS= read -r line || [ -n "$line" ]; do
            case $line in *' = '* | *' =') ;; *) continue ;; esac
            key=${line%%=*}
            key=${key%"${key##*[! ]}"}
            value=${line#*=}
            value=${value# }
            case $key in
                run_id) _rr_run_id=$value ;;
                conclusion) _rr_conclusion=$value ;;
                reason) _rr_reason=$value ;;
                first_seen) _rr_first=$value ;;
                policy) _rr_policy=$value ;;
                resolved_by) _rr_resolved_by=$value ;;
                resolved_at) _rr_resolved_at=$value ;;
            esac
        done < "$f"
    done
}

# Writes job $1's recovery record: run $2, conclusion $3, reason $4, policy
# $5, keeping first_seen and any resolution.
_vigil_sup_rec_write() {
    local f="$_su_statedir/recovery/$1.recovery"
    mkdir -p "$_su_statedir/recovery"
    {
        printf '[recovery]\n'
        printf 'job          = %s\n' "$1"
        printf 'run_id       = %s\n' "$2"
        printf 'conclusion   = %s\n' "$3"
        printf 'reason       = %s\n' "$4"
        printf 'first_seen   = %s\n' "${_rr_first:-$_su_epoch}"
        printf 'last_checked = %s\n' "$_su_epoch"
        printf 'policy       = %s\n' "$5"
        printf 'resolved_by  = %s\n' "$_rr_resolved_by"
        printf 'resolved_at  = %s\n' "$_rr_resolved_at"
    } > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
}

# Job $1's on_uncertain policy (6.6). Result in _su_policy.
_vigil_sup_policy() {
    local i=0
    _su_policy=wait
    vigil_config_effective "$1"
    while [ "$i" -lt "${#VIGIL_EFF_KEY[@]}" ]; do
        [ "${VIGIL_EFF_KEY[$i]}" = on_uncertain ] && _su_policy=${VIGIL_EFF_VALUE[$i]}
        i=$((i + 1))
    done
}

# An operator confirmed with vigil resolve that uncertain run $2 of job $1
# is over: record it as such and release the hold. Nothing is killed.
_vigil_sup_resolve() {
    local job=$1 rid=$2 token=$3
    if [ "$_ss" != final ]; then
        if [ "$_su_spool" = yes ]; then
            _vigil_sup_record "$job" "$rid" finished
        else
            _su_spool_outcome=''
            _vigil_sup_record "$job" "$rid" crashed "concluded by vigil resolve ($_rr_resolved_by)"
        fi
    fi
    [ -n "$token" ] && rm -f "$token"
    rm -f "$_su_statedir/locks/$job.$rid.timeout" "$_su_statedir/recovery/$job.recovery" "$_su_statedir/recovery/$job.resolved"
    _vigil_sup_log INFO "job $job: uncertain run $rid concluded, resolved by $_rr_resolved_by"
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
# rejected and the last valid one stays active (16.3): in state/config.valid,
# or with sources, the one state/config.active names (16.5). Returns 1 when
# there is no valid configuration at all.
_vigil_sup_config() {
    local sum
    sum=$(cksum < "$_su_root/config/vigil.config" 2>/dev/null)
    if [ "$sum" != "${_su_cfgsum-}" ]; then
        _su_cfgsum=$sum
        _vw_root=$_su_root
        _vw_job=-
        if ! vigil_config_parse "$_su_root/config/vigil.config" || ! vigil_config_validate; then
            _su_error='the configuration has errors; run vigil precheck'
            # Every problem, each on its own line (16.3).
            _su_report=$(vigil_config_report)
            [ -n "${_su_mode-}" ] || return 1
            _vigil_sup_log ERROR "configuration rejected, the last valid one stays active: $_su_error"
            while IFS= read -r _su_line; do
                [ -n "$_su_line" ] && _vigil_sup_log ERROR "  $_su_line"
            done <<EOF_REPORT
$_su_report
EOF_REPORT
            _su_reload_failed=1
            if [ "$_su_mode" = fetch ]; then
                _su_actsum=-
            else
                vigil_config_parse "$_su_valid" && vigil_config_validate
                return 0
            fi
        else
            _su_reload_failed=0
            _vigil_wk_dir vigil state_dir state
            _su_statedir=$_vw_dir
            if vigil_fetch_mode; then
                # What the fetcher last saw of this file tells whether it
                # must look again.
                _su_mode=fetch
                _su_local=$(_vigil_fetch_digest < "$_su_root/config/vigil.config")
                _su_actsum=-
            else
                _su_mode=local
                _su_waiting=0
                # A purely local configuration has a revision too (16.5).
                _su_revision=$(printf 'config %s\n' "$(_vigil_fetch_digest < "$_su_root/config/vigil.config")" | _vigil_fetch_digest)
                _su_revision=${_su_revision:0:12}
                _su_valid="$_su_statedir/config.valid"
                mkdir -p "$_su_statedir"
                cp "$_su_root/config/vigil.config" "$_su_valid.tmp.$$" && mv -f "$_su_valid.tmp.$$" "$_su_valid"
                _vigil_sup_settings
                _vigil_sup_log INFO "configuration loaded"
                return 0
            fi
        fi
    fi
    [ "$_su_mode" = fetch ] || return 0
    sum=$({ cksum < "$_su_statedir/config.active"; } 2>/dev/null)
    [ "$sum" = "$_su_actsum" ] && return 0
    _su_actsum=$sum
    if vigil_active_read "$_su_statedir" && vigil_config_parse "$VIGIL_ACT_CONFIG" && vigil_config_validate; then
        _su_waiting=0
        _vigil_sup_settings
        if [ "$VIGIL_ACT_REVISION" != "${_su_revision-}" ]; then
            _su_revision=$VIGIL_ACT_REVISION
            _vigil_sup_log INFO "configuration revision $_su_revision loaded ($VIGIL_ACT_ORIGIN)"
        fi
    else
        # Nothing fetched yet: no job runs until everything it needs is
        # present and verified (16.5).
        _su_waiting=1
        VIGIL_ACT_SRC=() VIGIL_ACT_FILE=() VIGIL_ACT_ENTRY=() VIGIL_ACT_SHA=()
        vigil_config_parse "$_su_root/config/vigil.config"
        vigil_config_validate
        _vigil_sup_settings
        _vigil_sup_log INFO "waiting for the first fetch from the configuration's sources"
    fi
}

# The settings of the active configuration; the state directory is always
# the local file's.
_vigil_sup_settings() {
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
}

# A job's cached script, when its file comes from a source. Returns 1 when
# it has none; sets _su_script (empty for a local file) otherwise.
_vigil_sup_script() {
    _su_script=''
    [ "$_su_mode" = fetch ] || return 0
    _vigil_wk_get "job.$1" source ''
    [ -n "$_vw_value" ] || return 0
    local src=$_vw_value
    _vigil_wk_get "job.$1" file ''
    vigil_active_script "$src" "$_vw_value" && [ -f "$_va_path" ] || return 1
    _su_script=$_va_path
}

# Whether the fetcher should run: when no fetch has been made, when the
# local file changed since the last, or when a source is due (16.5).
_vigil_sup_fetch_due() {
    local line next='' local=''
    [ -f "$_su_statedir/fetch.next" ] || return 0
    while IFS= read -r line; do
        case $line in
            'next_epoch = '*) next=${line#*= } ;;
            'local = '*) local=${line#*= } ;;
        esac
    done < "$_su_statedir/fetch.next"
    [ "$local" != "$_su_local" ] && return 0
    [ -z "$next" ] || [ "$_su_epoch" -ge "$next" ]
}

# Whether the forwarder should run: at each check_every, once any backoff is
# over, when a log has grown since its last run (13.4.3).
_vigil_sup_logs_due() {
    local line checked=0 next=0 total=''
    if [ -f "$_su_statedir/logs/forwarder.state" ]; then
        while IFS= read -r line; do
            case $line in
                'checked_epoch = '*) checked=${line#*= } ;;
                'next_try = '*) next=${line#*= } ;;
                'total = '*) total=${line#*= } ;;
            esac
        done < "$_su_statedir/logs/forwarder.state"
    fi
    _vigil_wk_get log_forward check_every 30s
    _vigil_wk_secs "$_vw_value"
    [ "$_su_epoch" -ge $((checked + _vw_secs)) ] || return 1
    [ "$_su_epoch" -ge "$next" ] || return 1
    vigil_logs_total "$_su_logdir"
    [ "$_vl_total" != "$total" ]
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
        # The configuration and script the run uses (16.5), whatever is
        # activated while it runs.
        if [ "$_su_mode" = fetch ] && [ "$job" != vigil_fetch ]; then
            printf 'config        = %s\n' "$VIGIL_ACT_CONFIG"
            if [ -n "${2-}" ]; then printf 'script        = %s\n' "$2"; fi
        fi
    } > "$_su_statedir/locks/$job.$rid.launch.tmp.$$" &&
        mv -f "$_su_statedir/locks/$job.$rid.launch.tmp.$$" "$_su_statedir/locks/$job.$rid.launch" || return 1
    # The worker must not inherit the supervisor lock (fd 8), or it would
    # keep the lock held after the supervisor exits.
    ( trap '' HUP; exec 8>&-; exec "$BASH" "$_su_app/vigil" --root "$_su_root" worker "$job" --run-id "$rid" ) \
        < /dev/null > /dev/null 2>&1 &
    _su_running=$((_su_running + 1))
    # The forwarder's own starts are not logged: each would give it
    # something new to forward.
    case $job in
        vigil_sender | vigil_logs) ;;
        *) _vigil_sup_log INFO "job $job: run $rid started" ;;
    esac
    # Started beside an uncertain run under on_uncertain = replace (11.4).
    if _vigil_sup_contains "$_su_replacing" "$job"; then
        _vigil_sup_event "$job" possible_duplicates 1 count
        _vigil_sup_log WARN "job $job: run $rid started beside an uncertain run (on_uncertain = replace)"
    fi
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
    local s name job cursor cfile active next i ok
    set -- $(date '+%s %Y-%m-%dT%H:%M:%S%z %Y-%m-%d')
    _su_epoch=$1
    _su_now=$2
    _su_date=$3
    _su_iso=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    _su_events=()
    _su_running=0
    _su_uncertain=''
    _su_replacing=''
    _su_crashed=''
    _su_status_running=''
    _su_status_waiting=''
    _su_status_disabled=''
    _su_status_invalid=''
    _su_status_last=''

    _su_status_missing=''

    _vigil_sup_config

    s=0
    while [ "$s" -lt "${#VIGIL_CFG_SEC_NAME[@]}" ]; do
        name=${VIGIL_CFG_SEC_NAME[$s]}
        s=$((s + 1))
        case $name in job.*) ;; *) continue ;; esac
        [ "$_su_waiting" = 1 ] && break
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

        # A script from a source that is not cached: FILE MISSING until it
        # is fetched again (16.3, 16.5).
        if ! _vigil_sup_script "$job"; then
            _vigil_sup_event "$job" file_missing 1 gauge
            _su_status_missing="$_su_status_missing $job"
            continue
        fi

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
            _vigil_sup_script "$job" || continue
            _vigil_sup_start "$job" "$_su_script"
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
    # The active revision, and how long since each source was last
    # checked successfully (14.5).
    if [ "$_su_waiting" = 0 ]; then
        _su_events[${#_su_events[@]}]="$_su_epoch vigil.config.info 1 gauge $_su_tags revision=$_su_revision"
        vigil_logs_enabled && _su_events[${#_su_events[@]}]="$_su_epoch vigil.logs.enabled 1 gauge $_su_tags"
    fi
    if [ "$_su_mode" = fetch ]; then
        for i in "$_su_statedir"/sources/*.state; do
            [ -f "$i" ] || continue
            ok=$(sed -n 's/^ok_epoch *= *//p' "$i")
            [ -n "$ok" ] || continue
            name=${i##*/}
            _su_events[${#_su_events[@]}]="$_su_epoch vigil.source.check_age $((_su_epoch - ok)) gauge $_su_tags source=${name%.state}"
        done
    fi

    # The supervisor's events for this tick (4.5).
    mkdir -p "$_su_spooldir/incoming"
    i="$_su_spooldir/incoming/$_su_epoch-vigil_supervisor.events"
    s=0
    while [ "$s" -lt "${#_su_events[@]}" ]; do
        printf '%s\n' "${_su_events[$s]}"
        s=$((s + 1))
    done > "$i.tmp.$$" && mv -f "$i.tmp.$$" "$i"

    # The sender (4.5): one at a time, started whenever the spool holds
    # anything. It is Vigil's own worker and does not count against
    # max_concurrent.
    _vigil_sup_account vigil_sender
    if [ "$_su_active" = - ] && [ "$_su_waiting" = 0 ]; then
        for i in "$_su_spooldir"/incoming/*.events "$_su_spooldir"/fanout/*.events "$_su_spooldir"/backends/*/*.events; do
            if [ -f "$i" ]; then
                _vigil_sup_start vigil_sender
                break
            fi
        done
    fi

    # The fetcher (16.5): like the sender, one at a time, outside
    # max_concurrent, so a slow source never delays a tick.
    if [ "$_su_mode" = fetch ]; then
        _vigil_sup_account vigil_fetch
        if [ "$_su_active" = - ] && _vigil_sup_fetch_due; then
            _vigil_sup_start vigil_fetch
        fi
    fi

    # Retention (13.1): at the start, then once a day.
    if [ "$_su_waiting" = 0 ] && [ "${_su_retained-}" != $((_su_epoch / 86400)) ]; then
        _su_retained=$((_su_epoch / 86400))
        vigil_logs_retention "$_su_logdir" "$_su_epoch"
        [ "$_vl_removed" -eq 0 ] || _vigil_sup_log INFO "retention: deleted $_vl_removed old log files"
    fi

    # The log forwarder (13.4.3): the same again, on its own schedule.
    if [ "$_su_waiting" = 0 ] && vigil_logs_enabled; then
        _vigil_sup_account vigil_logs
        if [ "$_su_active" = - ] && _vigil_sup_logs_due; then
            _vigil_sup_start vigil_logs
        fi
    fi

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
        if [ "$_su_mode" = fetch ]; then
            printf '\nSOURCES\n'
            if [ "$_su_waiting" = 1 ]; then
                printf '  waiting for the first fetch\n'
            else
                printf '  revision %s (%s)\n' "$_su_revision" "$VIGIL_ACT_ORIGIN"
            fi
            j=''
            if [ -f "$_su_statedir/jobs/vigil_fetch.state" ] &&
                grep '^status *= *failed' "$_su_statedir/jobs/vigil_fetch.state" > /dev/null 2>&1; then
                j=$(sed -n 's/^reason *= *//p' "$_su_statedir/jobs/vigil_fetch.state")
                printf '  last fetch failed: %s\n' "$j"
            fi
        fi
        if [ -n "$_su_status_missing" ]; then
            printf '\nFILE MISSING\n'
            for j in $_su_status_missing; do printf '  %s\n' "$j"; done
        fi
        if [ -n "$_su_uncertain" ]; then
            printf '\nUNCERTAIN\n'
            printf '%s' "$_su_uncertain" | sed 's/^/  /'
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
        [ -z "${_su_report-}" ] || printf '%s\n' "$_su_report" | sed 's/^/  /' >&2
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
    # Temporary files a killed supervisor left mid-write (12.3). Only the
    # supervisor writes these, and it now holds the lock, so none is live.
    rm -f "$_su_statedir"/schedule/*.tmp.* "$_su_statedir"/config.valid.tmp.* \
        "$_su_statedir"/locks/*.launch.tmp.* \
        "$_su_logdir"/supervisor/jobs.log.tmp.* "$_su_spooldir"/incoming/*-vigil_supervisor.events.tmp.*
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
