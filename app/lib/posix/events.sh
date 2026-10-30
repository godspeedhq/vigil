# shellcheck shell=bash
#
# Vigil run events - bash 3.2 compatible.
#
# Builds the spool events of one finished run (SPECIFICATION.md 4.5, 14):
# the per-job metrics of 14.2 and the metrics the job printed (14.3, 14.4),
# each with its tags. A pure function of the configuration, the run and the
# parsed output. Must produce exactly the same result as Events.ps1 -
# tests/conformance/events holds the shared cases.
#
#   vigil_run_events <job id> <ended epoch> <outcome> <exit code|-> \
#                    <duration seconds> <host> <os>
#     outcome  succeeded, warning, failed, unknown (10.2) or timed_out (10.3)
#     Uses the job's effective settings and VIGIL_MET_* from
#     vigil_metrics_parse.
#   Sets VIGIL_EVT[i]: "<epoch> <name> <value> <gauge|count> <key=value>..."
#
#   vigil_run_events_dump  prints them, one per line.
#
# Tags, in order: host, os, instance, job, then the [tags] section and the
# job's tags (as merged in 6.6), then any added by the event itself. A
# line's own tag replaces one of the same key in place.
#
# Requires config.sh, effective.sh and metrics.sh.

# Tags with key=value $2 applied to tag string $1: replaced in place when
# the key is present, appended otherwise. Result in _ve_tags.
_vigil_evt_tag() {
    local key=${2%%=*} t out='' found=0
    local IFS=' '
    set -f
    for t in $1; do
        if [ "${t%%=*}" = "$key" ]; then
            out="$out $2"
            found=1
        else
            out="$out $t"
        fi
    done
    set +f
    if [ "$found" -eq 0 ]; then out="$out $2"; fi
    _ve_tags=${out# }
}

_vigil_evt_add() {
    VIGIL_EVT[${#VIGIL_EVT[@]}]="$_ve_epoch $_ve_m.$1 $2 $3 $4"
}

vigil_run_events() {
    local id=$1 outcome=$3 code=$4 duration=$5 host=$6 os=$7 instance=vigil
    local base i rec name value type tags t
    local LC_ALL=C
    _ve_epoch=$2
    VIGIL_EVT=()

    vigil_config_section vigil
    if [ "$VIGIL_CFG_SEC" -ge 0 ]; then
        i=${VIGIL_CFG_SEC_FIRST[$VIGIL_CFG_SEC]}
        while [ "$i" -lt $((VIGIL_CFG_SEC_FIRST[VIGIL_CFG_SEC] + VIGIL_CFG_SEC_COUNT[VIGIL_CFG_SEC])) ]; do
            if [ "${VIGIL_CFG_KEY[$i]}" = instance ]; then instance=${VIGIL_CFG_VALUE[$i]}; break; fi
            i=$((i + 1))
        done
    fi

    vigil_config_effective "$id"
    base="host=$host os=$os instance=$instance job=$id"
    _ve_m=$id
    i=0
    while [ "$i" -lt "${#VIGIL_EFF_KEY[@]}" ]; do
        case ${VIGIL_EFF_KEY[$i]} in
            metric_name) _ve_m=${VIGIL_EFF_VALUE[$i]} ;;
            tag)
                _vigil_evt_tag "$base" "${VIGIL_EFF_VALUE[$i]}"
                base=$_ve_tags
                ;;
        esac
        i=$((i + 1))
    done

    # The per-job metrics of the run (14.2).
    _vigil_evt_add duration_seconds "$duration" gauge "$base"
    _vigil_evt_add runs 1 count "$base"
    case $outcome in
        succeeded) _vigil_evt_add succeeded 1 count "$base" ;;
        warning) _vigil_evt_add warnings 1 count "$base" ;;
        timed_out) _vigil_evt_add timeouts 1 count "$base" ;;
        *)
            if [ "$code" = - ]; then
                _vigil_evt_add failures 1 count "$base"
            else
                _vigil_evt_add failures 1 count "$base exit_code=$code"
            fi
            ;;
    esac

    # What the job printed: "METRIC <name> <value> <type> [tags]".
    i=0
    while [ "$i" -lt "${#VIGIL_MET_REC[@]}" ]; do
        rec=${VIGIL_MET_REC[$i]}
        i=$((i + 1))
        case $rec in METRIC\ *) ;; *) continue ;; esac
        set -f
        # shellcheck disable=SC2086
        set -- $rec
        set +f
        name=$2 value=$3 type=$4
        shift 4
        tags=$base
        for t in "$@"; do
            _vigil_evt_tag "$tags" "$t"
            tags=$_ve_tags
        done
        _vigil_evt_add "$name" "$value" "$type" "$tags"
    done

    if [ "$VIGIL_MET_INVALID" -gt 0 ]; then
        _vigil_evt_add invalid_metric_lines "$VIGIL_MET_INVALID" count "$base"
    fi
    if [ "$VIGIL_MET_DROPPED" -gt 0 ]; then
        _vigil_evt_add dropped_metric_lines "$VIGIL_MET_DROPPED" count "$base"
    fi
}

vigil_run_events_dump() {
    local i=0
    while [ "$i" -lt "${#VIGIL_EVT[@]}" ]; do
        printf '%s\n' "${VIGIL_EVT[$i]}"
        i=$((i + 1))
    done
}
