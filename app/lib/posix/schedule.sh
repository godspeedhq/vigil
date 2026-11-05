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
#             2026-10-29T20:00:00 (local, no offset) for run_at and cron,
#             or -
#     active  - (none), running or queued
#   Sets VIGIL_SCHED_DECISION (disabled, new, wait, missed, run, queue, skip,
#   or error for malformed input), VIGIL_SCHED_SLOT (the due slot or -) and
#   VIGIL_SCHED_NEXT (the next slot after now and the cursor, or -) and
#   VIGIL_SCHED_CURSOR (the cursor after this decision: - when deleted), slots in
#   cursor form.
#
# Times are handled as whole seconds with civil-date arithmetic, because
# converting dates with `date` differs between GNU and BSD. run_every slots
# are UTC seconds since the epoch; run_at and cron slots are local seconds
# (the local date and time counted as if it were UTC), so a time that occurs
# twice is one slot.
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

# --- cron (7.10) ---------------------------------------------------------------
# Standard five-field cron and its @ shorthands, nothing else. A field
# becomes a string of 0 and 1, one character per value from 0, so a value v
# is in the field when ${bits:v:1} is 1.

# Field $1 with values $2 to $3; $4 names the values from $2 up ("jan feb
# ..."), or is empty. Result in _vc_bits. Returns 1 with _vc_error set.
_vigil_cron_field() {
    local field=$1 lo=$2 hi=$3 names=$4 item base step a b v n
    local -a items
    # read, not a for loop over $field: a lone * would be taken as a file pattern.
    case $field in ,* | *,) _vc_error="has an empty item: '$field'"; return 1 ;; esac
    IFS=, read -r -a items <<< "$field"
    _vc_bits=$(printf "%0$((hi + 1))d" 0)
    for item in "${items[@]}"; do
        step=1
        base=$item
        case $item in
            */*)
                step=${item#*/}
                base=${item%%/*}
                case $step in '' | *[!0-9]*) _vc_error="has a step that is not a number: '$item'"; return 1 ;; esac
                step=$((10#$step))
                [ "$step" -ge 1 ] || { _vc_error="has a step below 1: '$item'"; return 1; }
                ;;
        esac
        case $base in
            '*') a=$lo b=$hi ;;
            ?*-?*) a=${base%%-*} b=${base#*-} ;;
            *)
                a=$base b=$base
                # 5/15 means from 5 to the end, every 15.
                [ "$item" = "$base" ] || b=$hi
                ;;
        esac
        for v in a b; do
            eval "n=\$$v"
            case $n in
                '' | *[!0-9a-zA-Z]*) _vc_error="has something that is not a value: '$item'"; return 1 ;;
                *[!0-9]*)
                    _vigil_lower "$n"
                    _vigil_cron_name "$_vigil_lowered" "$lo" "$names" || { _vc_error="has something that is not a value: '$item'"; return 1; }
                    n=$_vc_n
                    ;;
                *) n=$((10#$n)) ;;
            esac
            eval "$v=\$n"
        done
        if [ "$a" -lt "$lo" ] || [ "$b" -gt "$hi" ] || [ "$a" -gt "$b" ]; then
            _vc_error="has a value outside $lo-$hi: '$item'"
            return 1
        fi
        while [ "$a" -le "$b" ]; do
            _vc_bits=${_vc_bits:0:$a}1${_vc_bits:$((a + 1))}
            a=$((a + step))
        done
    done
}

# The value of name $1 among names $3 counted from $2. Result in _vc_n.
_vigil_cron_name() {
    local n=$2 w
    local IFS=' '
    for w in $3; do
        if [ "$w" = "$1" ]; then _vc_n=$n; return 0; fi
        n=$((n + 1))
    done
    return 1
}

# vigil_cron_parse <expression>
# Sets _vc_min, _vc_hour, _vc_dom, _vc_mon (index 1-12), _vc_dow (0-6,
# Sunday 0; 7 is Sunday too), and _vc_domstar, _vc_dowstar: 1 when that
# field starts with *, which decides how the two day fields combine. Returns
# 1 with _vc_error, the rest of a sentence that starts "'cron' ", when the
# expression is not standard cron or
# names no real date.
vigil_cron_parse() {
    local expr=$1 f m d
    local -a parts
    case $expr in
        @yearly | @annually) expr='0 0 1 1 *' ;;
        @monthly) expr='0 0 1 * *' ;;
        @weekly) expr='0 0 * * 0' ;;
        @daily | @midnight) expr='0 0 * * *' ;;
        @hourly) expr='0 * * * *' ;;
        @reboot) _vc_error="cannot be @reboot: a job runs at its times"; return 1 ;;
        @*) _vc_error="has an unknown shorthand '$expr': use five fields, or @hourly, @daily, @weekly, @monthly or @yearly"; return 1 ;;
    esac
    set -f
    # shellcheck disable=SC2206
    parts=($expr)
    set +f
    if [ "${#parts[@]}" -ne 5 ]; then
        _vc_error="needs five fields, minute hour day-of-month month day-of-week: '$1'"
        return 1
    fi
    _vigil_cron_field "${parts[0]}" 0 59 '' || return 1
    _vc_min=$_vc_bits
    _vigil_cron_field "${parts[1]}" 0 23 '' || return 1
    _vc_hour=$_vc_bits
    _vigil_cron_field "${parts[2]}" 1 31 '' || return 1
    _vc_dom=$_vc_bits
    _vigil_cron_field "${parts[3]}" 1 12 'jan feb mar apr may jun jul aug sep oct nov dec' || return 1
    _vc_mon=$_vc_bits
    _vigil_cron_field "${parts[4]}" 0 7 'sun mon tue wed thu fri sat' || return 1
    _vc_dow=$_vc_bits
    # 7 is Sunday as well as 0.
    [ "${_vc_dow:7:1}" = 1 ] && _vc_dow=1${_vc_dow:1}
    _vc_dow=${_vc_dow:0:7}
    _vc_domstar=0 _vc_dowstar=0
    case ${parts[2]} in '*'*) _vc_domstar=1 ;; esac
    case ${parts[4]} in '*'*) _vc_dowstar=1 ;; esac
    # A day of the month that no chosen month has (30 February) never runs.
    if [ "$_vc_dowstar" = 1 ] && [ "$_vc_domstar" = 0 ]; then
        for m in 1 2 3 4 5 6 7 8 9 10 11 12; do
            [ "${_vc_mon:$m:1}" = 1 ] || continue
            case $m in 2) f=29 ;; 4 | 6 | 9 | 11) f=30 ;; *) f=31 ;; esac
            d=1
            while [ "$d" -le "$f" ]; do
                [ "${_vc_dom:$d:1}" = 1 ] && return 0
                d=$((d + 1))
            done
        done
        _vc_error="matches no real date: '$1'"
        return 1
    fi
}

# Whether local day $1 (days since 1970-01-01) matches the job's cron days:
# its month, and its day of the month and of the week. When both day fields
# are restricted, either may match, as cron has it; otherwise both must.
_vigil_sched_cron_day() {
    local z=$(($1 + 719468)) era doe yoe doy mp d m w
    era=$((z / 146097))
    doe=$((z - era * 146097))
    yoe=$(((doe - doe / 1460 + doe / 36524 - doe / 146096) / 365))
    doy=$((doe - (365 * yoe + yoe / 4 - yoe / 100)))
    mp=$(((5 * doy + 2) / 153))
    d=$((doy - (153 * mp + 2) / 5 + 1))
    if [ "$mp" -lt 10 ]; then m=$((mp + 3)); else m=$((mp - 9)); fi
    w=$((($1 + 4) % 7))
    [ "${_vs_cmon:$m:1}" = 1 ] || return 1
    if [ "$_vs_cdomstar" = 1 ] || [ "$_vs_cdowstar" = 1 ]; then
        [ "${_vs_cdom:$d:1}" = 1 ] && [ "${_vs_cdow:$w:1}" = 1 ]
    else
        [ "${_vs_cdom:$d:1}" = 1 ] || [ "${_vs_cdow:$w:1}" = 1 ]
    fi
}

# The first cron slot after local seconds $1, or -1. Result in _vs_slot. Looks
# up to four years ahead: 29 February is within them.
_vigil_sched_cron_next() {
    local t=$(($1 / 60 * 60 + 60)) day h m k=0 hh mm
    day=$((t / 86400))
    h=$((t % 86400 / 3600))
    m=$((t % 3600 / 60))
    _vs_slot=-1
    while [ "$k" -lt 1462 ]; do
        if _vigil_sched_cron_day "$day"; then
            hh=$h
            while [ "$hh" -le 23 ]; do
                if [ "${_vs_chour:$hh:1}" = 1 ]; then
                    mm=$m
                    [ "$hh" -eq "$h" ] || mm=0
                    while [ "$mm" -le 59 ]; do
                        if [ "${_vs_cmin:$mm:1}" = 1 ]; then
                            _vs_slot=$((day * 86400 + hh * 3600 + mm * 60))
                            return 0
                        fi
                        mm=$((mm + 1))
                    done
                fi
                hh=$((hh + 1))
            done
        fi
        day=$((day + 1)) h=0 m=0 k=$((k + 1))
    done
}

# The latest cron slot at or before local seconds $1, or -1. Result in
# _vs_slot. Looks up to four years back.
_vigil_sched_cron_latest() {
    local t=$(($1 / 60 * 60)) day h m k=0 hh mm
    day=$((t / 86400))
    h=$((t % 86400 / 3600))
    m=$((t % 3600 / 60))
    _vs_slot=-1
    while [ "$k" -lt 1462 ] && [ "$day" -ge 0 ]; do
        if _vigil_sched_cron_day "$day"; then
            hh=$h
            while [ "$hh" -ge 0 ]; do
                if [ "${_vs_chour:$hh:1}" = 1 ]; then
                    mm=$m
                    [ "$hh" -eq "$h" ] || mm=59
                    while [ "$mm" -ge 0 ]; do
                        if [ "${_vs_cmin:$mm:1}" = 1 ]; then
                            _vs_slot=$((day * 86400 + hh * 3600 + mm * 60))
                            return 0
                        fi
                        mm=$((mm - 1))
                    done
                fi
                hh=$((hh - 1))
            done
        fi
        day=$((day - 1)) h=23 m=59 k=$((k + 1))
    done
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
    _vs_cron=0
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
            cron)
                # Validated already; a parse that fails leaves no slots.
                if vigil_cron_parse "$value"; then
                    _vs_cron=1
                    _vs_cmin=$_vc_min _vs_chour=$_vc_hour _vs_cdom=$_vc_dom _vs_cmon=$_vc_mon _vs_cdow=$_vc_dow
                    _vs_cdomstar=$_vc_domstar _vs_cdowstar=$_vc_dowstar
                fi
                ;;
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
                    j=$((k + 1))
                    _vs_mask=${_vs_mask:0:$k}1${_vs_mask:$j}
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
    local w=$((($1 + 4) % 7))
    [ "${_vs_mask:$w:1}" = 1 ]
}

# The latest slot at or before $1 (schedule seconds), or -1. Result in _vs_slot.
# $2 is the UTC offset, used for the local day of run_every slots. Looks back
# eight days: every allowed weekday is within a week.
_vigil_sched_latest() {
    local now=$1 off=$2 c k day i
    if [ "$_vs_cron" = 1 ]; then _vigil_sched_cron_latest "$1"; return 0; fi
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
    if [ "$_vs_cron" = 1 ]; then _vigil_sched_cron_next "$1"; return 0; fi
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
    # Byte-wise matching, whatever the caller's locale.
    local LC_ALL=C
    VIGIL_SCHED_DECISION=error
    VIGIL_SCHED_SLOT=-
    VIGIL_SCHED_NEXT=-
    VIGIL_SCHED_CURSOR=-

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
        _vigil_sched_format "$now_s" "$kind"
        VIGIL_SCHED_CURSOR=$_vs_text
        return 0
    fi

    _vigil_sched_latest "$now_s" "$now_off"
    slot=$_vs_slot
    if [ "$slot" -lt 0 ] || [ "$slot" -le "$cur" ]; then
        VIGIL_SCHED_DECISION=wait
        VIGIL_SCHED_CURSOR=$4
        return 0
    fi
    _vigil_sched_format "$slot" "$kind"
    VIGIL_SCHED_SLOT=$_vs_text
    # Every decision from here on moves the cursor to the slot.
    VIGIL_SCHED_CURSOR=$_vs_text

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

# vigil_schedule_busiest <now>
# The minute of the next 24 hours at which the most enabled jobs start (8,
# 16.4), from the parsed configuration; now as for vigil_schedule_decide.
# Sets VIGIL_SCHED_BUSY_COUNT (0 when nothing is scheduled) and
# VIGIL_SCHED_BUSY_AT, that minute's local time as HH:MM, the earliest of
# equals. A job counts once per minute. Local slots are taken at the current
# UTC offset. run_every slots are stepped through directly: one every minute
# is 1440 of them.
vigil_schedule_busiest() {
    local now_e off end s name c idx last best=0 bidx=-1 i
    local -a bucket
    bucket=()
    VIGIL_SCHED_BUSY_COUNT=0
    VIGIL_SCHED_BUSY_AT=''
    _vigil_sched_parse "$1" || return 1
    now_e=$_vs_secs off=$_vs_off
    end=$((now_e + 86400))
    s=0
    while [ "$s" -lt "${#VIGIL_CFG_SEC_NAME[@]}" ]; do
        name=${VIGIL_CFG_SEC_NAME[$s]}
        s=$((s + 1))
        case $name in job.*) ;; *) continue ;; esac
        _vigil_sched_job "${name#job.}" || continue
        [ "$_vs_enabled" = true ] || continue
        last=-1
        if [ "$_vs_every" -gt 0 ]; then
            c=$((now_e / _vs_every * _vs_every + _vs_every))
            while [ "$c" -lt "$end" ]; do
                idx=$((c / 60 - now_e / 60))
                if [ "$idx" -ne "$last" ] && _vigil_sched_day_ok $(((c + off) / 86400)); then
                    bucket[idx]=$((${bucket[idx]-0} + 1))
                    last=$idx
                fi
                c=$((c + _vs_every))
            done
        elif [ "$_vs_cron" = 1 ] || [ "${#_vs_times[@]}" -gt 0 ]; then
            c=$((now_e + off))
            while :; do
                _vigil_sched_next "$c" "$off"
                [ "$_vs_slot" -ge 0 ] && [ $((_vs_slot - off)) -lt "$end" ] || break
                c=$_vs_slot
                idx=$(((c - off) / 60 - now_e / 60))
                if [ "$idx" -ne "$last" ]; then
                    bucket[idx]=$((${bucket[idx]-0} + 1))
                    last=$idx
                fi
            done
        fi
    done
    for i in ${bucket[@]+"${!bucket[@]}"}; do
        if [ "${bucket[i]}" -gt "$best" ]; then
            best=${bucket[i]}
            bidx=$i
        fi
    done
    [ "$bidx" -ge 0 ] || return 0
    VIGIL_SCHED_BUSY_COUNT=$best
    _vigil_sched_format $(((now_e / 60 + bidx) * 60 + off)) local
    VIGIL_SCHED_BUSY_AT=${_vs_text:11:5}
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
