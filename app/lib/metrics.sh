# shellcheck shell=bash
#
# Vigil job output parsing - bash 3.2 compatible.
#
# Reads a finished run's captured stdout and extracts its metrics: "metric"
# lines (SPECIFICATION.md 14.3) and, for Nagios jobs, performance data
# (14.4). A pure function of the file and its arguments. Must produce
# exactly the same result as Metrics.ps1 - tests/conformance/metrics holds
# the shared cases.
#
#   vigil_metrics_parse <mode> <cap> <path>
#     mode  standard, or nagios to parse performance data as well
#     cap   the most metric lines and perfdata items taken from one run;
#           later ones are dropped and counted (VIGIL_METRIC_LINES_MAX is
#           the default)
#   Sets, in output order:
#     VIGIL_MET_REC[i]  "METRIC <name> <value> <gauge|count>[ <key=value>...]"
#                       or "INVALID <line>"
#   and the run summary VIGIL_MET_LINES, VIGIL_MET_INVALID, VIGIL_MET_DROPPED.
#   <name> is relative to the job's metric_name; tags are the line's own.
#
#   vigil_metrics_dump  prints the records, then
#                       "SUMMARY metric_lines=<n> invalid_lines=<n> dropped_lines=<n>"
#
# Numbers are handled as decimal strings, never as floating point, so unit
# conversion is exact and identical on both implementations: 11700MB is
# 12268339200 bytes, 250ms is 0.25 seconds.
#
# bash 3.2: no associative arrays.

VIGIL_METRIC_LINES_MAX=1000
VIGIL_METRIC_RESERVED_TAGS=$'\nhost\nos\ninstance\njob\nlabel\nuom\nexit_code\n'

_vigil_met_re_name='^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)*$'
_vigil_met_re_num='^-?[0-9]+(\.[0-9]+)?$'
_vigil_met_re_tag='^([A-Za-z0-9_]+)=(.+)$'
_vigil_met_re_perfval='^(-?[0-9]+(\.[0-9]+)?)([A-Za-z%]*)$'

# Canonical form of a number matching _vigil_met_re_num: no leading zeros,
# no trailing fractional zeros, no "-0". Result in _vm_num.
_vigil_met_canon() {
    local s=$1 sign='' int frac
    case $s in -*) sign=-; s=${s#-} ;; esac
    int=${s%%.*}
    frac=''
    case $s in *.*) frac=${s#*.} ;; esac
    while [ "${#int}" -gt 1 ] && [ "${int:0:1}" = 0 ]; do int=${int:1}; done
    while [ -n "$frac" ] && [ "${frac:${#frac}-1:1}" = 0 ]; do frac=${frac:0:${#frac}-1}; done
    _vm_num=$int
    if [ -n "$frac" ]; then _vm_num="$int.$frac"; fi
    if [ "$_vm_num" != 0 ]; then _vm_num=$sign$_vm_num; fi
}

# Scales a number by 1024^$2 and then by 10^-$3, exactly. Result in _vm_num.
_vigil_met_scale() {
    local s=$1 k=$2 d=$3 sign='' int frac digits flen i carry p out n
    case $s in -*) sign=-; s=${s#-} ;; esac
    int=${s%%.*}
    frac=''
    case $s in *.*) frac=${s#*.} ;; esac
    digits=$int$frac
    flen=${#frac}
    while [ "$k" -gt 0 ]; do
        # Multiply the digit string by 1024, right to left.
        out=''
        carry=0
        i=$((${#digits} - 1))
        while [ "$i" -ge 0 ]; do
            p=$((${digits:i:1} * 1024 + carry))
            out=$((p % 10))$out
            carry=$((p / 10))
            i=$((i - 1))
        done
        if [ "$carry" -gt 0 ]; then out=$carry$out; fi
        digits=$out
        k=$((k - 1))
    done
    flen=$((flen + d))
    while [ "${#digits}" -le "$flen" ]; do digits=0$digits; done
    n=$((${#digits} - flen))
    if [ "$flen" -gt 0 ]; then
        _vigil_met_canon "$sign${digits:0:n}.${digits:n}"
    else
        _vigil_met_canon "$sign$digits"
    fi
}

# Counts one candidate (a metric line or a perfdata item) against the cap.
# Returns 1, counting it as dropped, when the cap is reached.
_vigil_met_take() {
    if [ "$_vm_seen" -ge "$_vm_cap" ]; then
        VIGIL_MET_DROPPED=$((VIGIL_MET_DROPPED + 1))
        return 1
    fi
    _vm_seen=$((_vm_seen + 1))
    return 0
}

_vigil_met_invalid() {
    VIGIL_MET_INVALID=$((VIGIL_MET_INVALID + 1))
    VIGIL_MET_REC[${#VIGIL_MET_REC[@]}]="INVALID $1"
}

# One "metric <name> <value> [key=value ...]" line ($1), at line $2.
_vigil_met_line() {
    local nl=$'\n' name value tags='' key tok
    local seen=$nl
    local IFS=$' \t'
    set -f
    # shellcheck disable=SC2086
    set -- $1 "$2"
    set +f
    local n=${!#}
    _vigil_met_take || return 0
    if [ "$#" -lt 4 ]; then _vigil_met_invalid "$n"; return 0; fi
    name=$2
    value=$3
    shift 3
    if ! [[ $name =~ $_vigil_met_re_name ]] || ! [[ $value =~ $_vigil_met_re_num ]]; then
        _vigil_met_invalid "$n"
        return 0
    fi
    while [ "$#" -gt 1 ]; do
        tok=$1
        shift
        if ! [[ $tok =~ $_vigil_met_re_tag ]]; then _vigil_met_invalid "$n"; return 0; fi
        key=${BASH_REMATCH[1]}
        case $VIGIL_METRIC_RESERVED_TAGS$seen in
            *$nl"$key"$nl*) _vigil_met_invalid "$n"; return 0 ;;
        esac
        seen="$seen$key$nl"
        tags="$tags $tok"
    done
    _vigil_met_canon "$value"
    VIGIL_MET_LINES=$((VIGIL_MET_LINES + 1))
    VIGIL_MET_REC[${#VIGIL_MET_REC[@]}]="METRIC $name $_vm_num gauge$tags"
}

# One perfdata item: label $1, "value[UOM];warn;crit;min;max" $2, line $3.
_vigil_met_perfitem() {
    local label=$1 spec=$2 n=$3 rest f value unit k=0 d=0 uom='' type=gauge i
    local -a fields
    # A value of U (undetermined) is not a measurement.
    case $spec in U | 'U;'*) return 0 ;; esac
    _vigil_met_take || return 0
    fields=()
    rest=$spec
    while :; do
        fields[${#fields[@]}]=${rest%%;*}
        case $rest in *\;*) rest=${rest#*;} ;; *) break ;; esac
    done
    if [ -z "$label" ] || [ "${#fields[@]}" -gt 5 ] || ! [[ ${fields[0]} =~ $_vigil_met_re_perfval ]]; then
        _vigil_met_invalid "$n"
        return 0
    fi
    value=${BASH_REMATCH[1]}
    unit=${BASH_REMATCH[3]}
    case $unit in
        '' | s | B | %) ;;
        ms) d=3 ;;
        us) d=6 ;;
        KB) k=1 ;;
        MB) k=2 ;;
        GB) k=3 ;;
        TB) k=4 ;;
        c) type=count ;;
        *) uom=" uom=$unit" ;;
    esac
    # Tag values cannot contain spaces.
    label=${label// /_}
    VIGIL_MET_LINES=$((VIGIL_MET_LINES + 1))
    _vigil_met_scale "$value" "$k" "$d"
    VIGIL_MET_REC[${#VIGIL_MET_REC[@]}]="METRIC perf $_vm_num $type label=$label$uom"
    i=1
    for f in warn crit min max; do
        if [ "$i" -lt "${#fields[@]}" ] && [[ ${fields[$i]} =~ $_vigil_met_re_num ]]; then
            _vigil_met_scale "${fields[$i]}" "$k" "$d"
            VIGIL_MET_REC[${#VIGIL_MET_REC[@]}]="METRIC perf.$f $_vm_num gauge label=$label$uom"
        fi
        i=$((i + 1))
    done
}

# The perfdata of one line ($1, the text after its first "|"), at line $2.
# Items are separated by spaces; a label may be quoted to hold spaces or
# "=", with '' for a literal quote.
_vigil_met_perf() {
    local s=$1 n=$2 i=0 len=${#1} c label spec ok
    while :; do
        while [ "$i" -lt "$len" ]; do
            c=${s:i:1}
            case $c in ' ' | '	') i=$((i + 1)) ;; *) break ;; esac
        done
        [ "$i" -ge "$len" ] && return 0
        label=''
        ok=1
        if [ "${s:i:1}" = "'" ]; then
            i=$((i + 1))
            ok=0
            while [ "$i" -lt "$len" ]; do
                c=${s:i:1}
                if [ "$c" = "'" ]; then
                    if [ "${s:i+1:1}" = "'" ]; then
                        label="$label'"
                        i=$((i + 2))
                        continue
                    fi
                    i=$((i + 1))
                    ok=1
                    break
                fi
                label=$label$c
                i=$((i + 1))
            done
            if [ "$ok" -eq 0 ]; then
                # An unterminated quote takes the rest of the line with it.
                _vigil_met_take && _vigil_met_invalid "$n"
                return 0
            fi
            [ "${s:i:1}" = = ] || ok=0
        else
            while [ "$i" -lt "$len" ]; do
                c=${s:i:1}
                case $c in = | ' ' | '	') break ;; esac
                label=$label$c
                i=$((i + 1))
            done
            [ "${s:i:1}" = = ] || ok=0
        fi
        # The value part runs to the next space; a malformed item ends there too.
        [ "$ok" -eq 1 ] && i=$((i + 1))
        spec=''
        while [ "$i" -lt "$len" ]; do
            c=${s:i:1}
            case $c in ' ' | '	') break ;; esac
            spec=$spec$c
            i=$((i + 1))
        done
        if [ "$ok" -eq 1 ]; then
            _vigil_met_perfitem "$label" "$spec" "$n"
        else
            _vigil_met_take && _vigil_met_invalid "$n"
        fi
    done
}

vigil_metrics_parse() {
    local mode=$1 path=$3 line n=0
    local LC_ALL=C
    _vm_cap=$2
    _vm_seen=0
    VIGIL_MET_REC=()
    VIGIL_MET_LINES=0
    VIGIL_MET_INVALID=0
    VIGIL_MET_DROPPED=0
    [ -f "$path" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        line=${line%$'\r'}
        case $line in
            metric | 'metric '* | 'metric	'*)
                _vigil_met_line "$line" "$n"
                continue
                ;;
        esac
        if [ "$mode" = nagios ]; then
            case $line in
                *'|'*) _vigil_met_perf "${line#*|}" "$n" ;;
            esac
        fi
    done < "$path"
    return 0
}

vigil_metrics_dump() {
    local i=0
    while [ "$i" -lt "${#VIGIL_MET_REC[@]}" ]; do
        printf '%s\n' "${VIGIL_MET_REC[$i]}"
        i=$((i + 1))
    done
    printf 'SUMMARY metric_lines=%s invalid_lines=%s dropped_lines=%s\n' "$VIGIL_MET_LINES" "$VIGIL_MET_INVALID" "$VIGIL_MET_DROPPED"
}
