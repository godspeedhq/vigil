# shellcheck shell=bash
#
# Vigil schedule decisions - bash 3.2 compatible.
#
# Decides, for one job at one tick, what the supervisor does about its
# schedule (SPECIFICATION.md 7.9). A pure function of its inputs: nothing is
# read from the clock or written to disk here. Must produce exactly the same
# result as Schedule.ps1 - tests/conformance/schedule holds the shared table.
#
#   vigil_schedule_decide <job id> <now> <prev> <cursor> <active>
#     now     local time and UTC offset, 2026-10-29T14:00:00+0100
#     prev    the previous tick in the same form, or -
#     cursor  the last slot dealt with: 2026-10-29T13:55:00Z for run_every,
#             2026-10-29T20:00:00 (local, no offset) for run_at, or -
#     active  - (none), running or queued
#   Sets VIGIL_SCHED_DECISION (disabled, new, wait, missed, run, queue, skip,
#   or error for malformed input), VIGIL_SCHED_SLOT (the due slot or -) and
#   VIGIL_SCHED_NEXT (the next slot after now and the cursor, or -), slots in
#   cursor form.
#
# Times are handled as whole seconds with civil-date arithmetic, because
# converting dates with `date` differs between GNU and BSD. run_every slots
# are UTC seconds since the epoch; run_at slots are local seconds (the local
# date and time counted as if it were UTC), so a time that occurs twice is
# one slot.
#
# Requires config.sh and effective.sh. bash 3.2: no associative arrays.

_vigil_sched_re_time='^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(Z|[+-][0-9]{4})?$'

# Days since 1970-01-01 of a civil date. Result in _vs_days.
# (Howard Hinnant's days_from_civil, for years from 1970.)
_vigil_sched_days() {
    local y=$1 m=$2 d=$3 mp era yoe doe
    if [ "$m" -le 2 ]; then y=$((y - 1)); mp=$((m + 9)); else mp=$((m - 3)); fi
    era=$((y / 400))
    yoe=$((y - era * 400))
    doe=$((yoe * 365 + yoe / 4 - yoe / 100 + (153 * mp + 2) / 5 + d - 1))
    _vs_days=$((era * 146097 + doe - 719468))
}

# Formats seconds as 2026-10-29T20:00:00, with a Z suffix when $2 is utc.
# Result in _vs_text.
_vigil_sched_format() {
    local s=$1 z era doe yoe y doy mp d m
    z=$((s / 86400 + 719468))
    era=$((z / 146097))
    doe=$((z - era * 146097))
    yoe=$(((doe - doe / 1460 + doe / 36524 - doe / 146096) / 365))
    y=$((yoe + era * 400))
    doy=$((doe - (365 * yoe + yoe / 4 - yoe / 100)))
    mp=$(((5 * doy + 2) / 153))
    d=$((doy - (153 * mp + 2) / 5 + 1))
    if [ "$mp" -lt 10 ]; then m=$((mp + 3)); else m=$((mp - 9)); fi
    if [ "$m" -le 2 ]; then y=$((y + 1)); fi
    s=$((s % 86400))
    printf -v _vs_text '%04d-%02d-%02dT%02d:%02d:%02d' "$y" "$m" "$d" \
        $((s / 3600)) $((s % 3600 / 60)) $((s % 60))
    if [ "$2" = utc ]; then _vs_text=${_vs_text}Z; fi
}

# Parses a time. Sets _vs_kind (offset, utc or local), _vs_secs (UTC seconds
# for offset and utc, local seconds for local) and _vs_off (the offset in
# seconds, for offset). Returns 1 when malformed.
_vigil_sched_parse() {
    [[ $1 =~ $_vigil_sched_re_time ]] || return 1
    local y=$((10#${BASH_REMATCH[1]})) m=$((10#${BASH_REMATCH[2]})) d=$((10#${BASH_REMATCH[3]}))
    local hh=$((10#${BASH_REMATCH[4]})) mi=$((10#${BASH_REMATCH[5]})) ss=$((10#${BASH_REMATCH[6]}))
    local zone=${BASH_REMATCH[7]}
    if [ "$y" -lt 1970 ] || [ "$m" -lt 1 ] || [ "$m" -gt 12 ] || [ "$d" -lt 1 ] || [ "$d" -gt 31 ] ||
        [ "$hh" -gt 23 ] || [ "$mi" -gt 59 ] || [ "$ss" -gt 59 ]; then
        return 1
    fi
    _vigil_sched_days "$y" "$m" "$d"
    _vs_secs=$((_vs_days * 86400 + hh * 3600 + mi * 60 + ss))
    _vs_off=0
    case $zone in
        '') _vs_kind=local ;;
        Z) _vs_kind=utc ;;
        *)
            _vs_kind=offset
            _vs_off=$((10#${zone:1:2} * 3600 + 10#${zone:3:2} * 60))
            if [ "${zone:0:1}" = - ]; then _vs_off=$((-_vs_off)); fi
            _vs_secs=$((_vs_secs - _vs_off))
            ;;
    esac
}

# Seconds in a validated duration such as 30s, 5m, 2h or 7d. Result in _vs_dur.
_vigil_sched_dur() {
    local n=$((10#${1%?}))
    case $1 in
        *s) _vs_dur=$n ;;
        *m) _vs_dur=$((n * 60)) ;;
        *h) _vs_dur=$((n * 3600)) ;;
        *d) _vs_dur=$((n * 86400)) ;;
    esac
}

# Loads a job's effective schedule settings, cached per job and parse.
# Returns 1 when the job does not exist.
_vigil_sched_job() {
    if [ "$1" = "${_vs_job-}" ] && [ "$VIGIL_CFG_GENERATION" = "${_vs_gen-}" ]; then
        return 0
    fi
    _vs_job=''
    vigil_config_section "job.$1"
    [ "$VIGIL_CFG_SEC" -ge 0 ] || return 1
    vigil_config_effective "$1"

    _vs_every=0
    _vs_times=()
    _vs_mask=1111111
    _vs_window=0
    _vs_overlap=skip
    _vs_enabled=true
    local i=0 key value item t j k
    while [ "$i" -lt "${#VIGIL_EFF_KEY[@]}" ]; do
        key=${VIGIL_EFF_KEY[$i]}
        value=${VIGIL_EFF_VALUE[$i]}
        case $key in
            run_every) _vigil_sched_dur "$value"; _vs_every=$_vs_dur ;;
            late_start_window) _vigil_sched_dur "$value"; _vs_window=$_vs_dur ;;
            overlap) _vs_overlap=$value ;;
            enabled) _vs_enabled=$value ;;
            run_at)
                # "01:00, 13:00" -> seconds after midnight, ascending.
                _vigil_eff_split "$value"
                for item in "${_ve_items[@]}"; do
                    t=$((10#${item%%:*} * 3600 + 10#${item#*:} * 60))
                    j=${#_vs_times[@]}
                    while [ "$j" -gt 0 ] && [ "${_vs_times[$((j - 1))]}" -gt "$t" ]; do
                        _vs_times[$j]=${_vs_times[$((j - 1))]}
                        j=$((j - 1))
                    done
                    _vs_times[$j]=$t
                done
                ;;
            run_on_days)
                # A character per weekday, Sunday first.
                _vs_mask=0000000
                _vigil_eff_split "$value"
                for item in "${_ve_items[@]}"; do
                    _vigil_lower "$item"
                    case $_vigil_lowered in
                        sun) k=0 ;; mon) k=1 ;; tue) k=2 ;; wed) k=3 ;;
                        thu) k=4 ;; fri) k=5 ;; sat) k=6 ;;
                    esac
                    _vs_mask=${_vs_mask:0:k}1${_vs_mask:k+1}
                done
                ;;
        esac
        i=$((i + 1))
    done

    _vigil_eff_get scheduler tick
    if [ "$_ve_found" -eq 1 ]; then _vigil_sched_dur "$_ve_value"; else _vs_dur=60; fi
    _vs_tick=$_vs_dur

    _vs_job=$1
    _vs_gen=$VIGIL_CFG_GENERATION
}

# Whether day number $1 (days since 1970-01-01, a Thursday) is allowed.
_vigil_sched_day_ok() {
    [ "${_vs_mask:$((($1 + 4) % 7)):1}" = 1 ]
}

# The latest slot at or before $1 (schedule seconds), or -1. Result in _vs_slot.
# $2 is the UTC offset, used for the local day of run_every slots. Looks back
# eight days: every allowed weekday is within a week.
_vigil_sched_latest() {
    local now=$1 off=$2 c k day i
    _vs_slot=-1
    if [ "$_vs_every" -gt 0 ]; then
        c=$((now / _vs_every * _vs_every))
        k=0
        while [ "$k" -lt 8 ]; do
            day=$(((c + off) / 86400))
            if _vigil_sched_day_ok "$day"; then _vs_slot=$c; return 0; fi
            # The last slot before that local day began.
            c=$(((day * 86400 - off - 1) / _vs_every * _vs_every))
            k=$((k + 1))
        done
    else
        day=$((now / 86400))
        k=0
        while [ "$k" -lt 8 ]; do
            if _vigil_sched_day_ok "$day"; then
                i=$((${#_vs_times[@]} - 1))
                while [ "$i" -ge 0 ]; do
                    c=$((day * 86400 + _vs_times[i]))
                    if [ "$c" -le "$now" ]; then _vs_slot=$c; return 0; fi
                    i=$((i - 1))
                done
            fi
            day=$((day - 1))
            k=$((k + 1))
        done
    fi
}

# The first slot after $1 (schedule seconds), or -1. Result in _vs_slot.
_vigil_sched_next() {
    local now=$1 off=$2 c k day i
    _vs_slot=-1
    if [ "$_vs_every" -gt 0 ]; then
        c=$((now / _vs_every * _vs_every + _vs_every))
        k=0
        while [ "$k" -lt 8 ]; do
            day=$(((c + off) / 86400))
            if _vigil_sched_day_ok "$day"; then _vs_slot=$c; return 0; fi
            # The first slot once the next local day begins.
            c=$((((day + 1) * 86400 - off + _vs_every - 1) / _vs_every * _vs_every))
            k=$((k + 1))
        done
    else
        day=$((now / 86400))
        k=0
        while [ "$k" -lt 8 ]; do
            if _vigil_sched_day_ok "$day"; then
                i=0
                while [ "$i" -lt "${#_vs_times[@]}" ]; do
                    c=$((day * 86400 + _vs_times[i]))
                    if [ "$c" -gt "$now" ]; then _vs_slot=$c; return 0; fi
                    i=$((i + 1))
                done
            fi
            day=$((day + 1))
            k=$((k + 1))
        done
    fi
}

# vigil_schedule_decide <job id> <now> <prev> <cursor> <active>
# Returns 1 (decision error) when the job is unknown or an input is malformed.
vigil_schedule_decide() {
    local now_e now_off now_s prev_e='' prev_s='' cur='' kind slot age ontime
    VIGIL_SCHED_DECISION=error
    VIGIL_SCHED_SLOT=-
    VIGIL_SCHED_NEXT=-

    _vigil_sched_job "$1" || return 1
    if [ "$_vs_every" -gt 0 ]; then kind=utc; else kind=local; fi

    _vigil_sched_parse "$2" && [ "$_vs_kind" = offset ] || return 1
    now_e=$_vs_secs
    now_off=$_vs_off
    if [ "$kind" = utc ]; then now_s=$now_e; else now_s=$((now_e + now_off)); fi

    if [ "$3" != - ]; then
        _vigil_sched_parse "$3" && [ "$_vs_kind" = offset ] || return 1
        prev_e=$_vs_secs
        if [ "$kind" = utc ]; then prev_s=$prev_e; else prev_s=$((prev_e + _vs_off)); fi
    fi
    if [ "$4" != - ]; then
        _vigil_sched_parse "$4" && [ "$_vs_kind" = "$kind" ] || return 1
        cur=$_vs_secs
    fi
    case $5 in
        - | running | queued) ;;
        *) return 1 ;;
    esac

    if [ "$_vs_enabled" = false ]; then
        VIGIL_SCHED_DECISION=disabled
        return 0
    fi

    # The next slot that can run: after now and after the cursor, so a clock
    # set back does not report a slot that will be passed over.
    if [ -n "$cur" ] && [ "$cur" -gt "$now_s" ]; then
        _vigil_sched_next "$cur" "$now_off"
    else
        _vigil_sched_next "$now_s" "$now_off"
    fi
    if [ "$_vs_slot" -ge 0 ]; then
        _vigil_sched_format "$_vs_slot" "$kind"
        VIGIL_SCHED_NEXT=$_vs_text
    fi

    if [ -z "$cur" ]; then
        VIGIL_SCHED_DECISION=new
        return 0
    fi

    _vigil_sched_latest "$now_s" "$now_off"
    slot=$_vs_slot
    if [ "$slot" -lt 0 ] || [ "$slot" -le "$cur" ]; then
        VIGIL_SCHED_DECISION=wait
        return 0
    fi
    _vigil_sched_format "$slot" "$kind"
    VIGIL_SCHED_SLOT=$_vs_text

    # Ticking normally and the slot came after the previous tick: this is the
    # first tick at or after it. Otherwise the late-start window applies.
    ontime=0
    if [ -n "$prev_e" ] && [ "$now_e" -ge "$prev_e" ] &&
        [ $((now_e - prev_e)) -le $((2 * _vs_tick)) ] && [ "$slot" -gt "$prev_s" ]; then
        ontime=1
    else
        if [ "$kind" = utc ]; then age=$((now_e - slot)); else age=$((now_s - slot)); fi
        if [ "$age" -le "$_vs_window" ]; then ontime=1; fi
    fi

    if [ "$ontime" -eq 0 ]; then
        VIGIL_SCHED_DECISION=missed
    elif [ "$5" = - ]; then
        VIGIL_SCHED_DECISION=run
    elif [ "$5" = running ] && [ "$_vs_overlap" = queue_one ]; then
        VIGIL_SCHED_DECISION=queue
    else
        VIGIL_SCHED_DECISION=skip
    fi
}

# vigil_schedule_table_dump <table file>
# Reads a decisions table - one row per tick, whitespace-separated:
#   <job> <now> <prev> <cursor> <active> <decision> <slot> <next>
# blank lines and # comments ignored - and prints each row with the last three
# columns computed, single-space separated.
vigil_schedule_table_dump() {
    local job now prev cursor active rest
    while read -r job now prev cursor active rest || [ -n "$job" ]; do
        case $job in '' | '#'*) continue ;; esac
        vigil_schedule_decide "$job" "$now" "$prev" "$cursor" "$active"
        printf '%s %s %s %s %s %s %s %s\n' "$job" "$now" "$prev" "$cursor" "$active" \
            "$VIGIL_SCHED_DECISION" "$VIGIL_SCHED_SLOT" "$VIGIL_SCHED_NEXT"
    done < "$1"
}
