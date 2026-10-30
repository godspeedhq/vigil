# shellcheck shell=bash
#
# Vigil file backend - bash 3.2 compatible.
#
# Merges spool events into a Prometheus text file, as node_exporter's
# textfile collector reads it (SPECIFICATION.md 15.3). The file holds the
# current value of every series: a gauge's latest value, and a count's
# running total as a counter. A pure function of the old file and the
# events. Must produce exactly the same result as Prom.ps1 -
# tests/conformance/prom holds the shared cases.
#
#   vigil_prom_merge <old .prom file, or -> <events file>...
#     Prints the new file. Events are applied in the order given, so the
#     latest gauge value wins.
#
# Naming: dots become underscores, a name or label starting with a digit
# gets a leading underscore, and counters end in _total. Labels are the
# event's tags, sorted by key, with \ and " escaped. A count whose value is
# not a whole number is written as a gauge. Series are sorted, so the same
# state always gives the same file. No timestamps: the textfile collector
# rejects them.

# A Prometheus name from a Vigil one. Result in _vp_name.
_vigil_prom_name() {
    _vp_name=${1//./_}
    case $_vp_name in [0-9]*) _vp_name=_$_vp_name ;; esac
}

# One event line as "<name>\t<labels>\t<type>\t<value>". Result in _vp_rec;
# empty for a line that is not an event.
_vigil_prom_event() {
    local epoch name value type tag key val labels='' sorted IFS=' '
    _vp_rec=''
    set -f
    # shellcheck disable=SC2086
    set -- $1
    set +f
    [ "$#" -ge 4 ] || return 0
    name=$2 value=$3 type=$4
    shift 4
    _vigil_prom_name "$name"
    name=$_vp_name
    case $type:$value in
        count:*[!0-9-]* | count:-*-* | count:) type=gauge ;;
        count:*) type=counter; case $name in *_total) ;; *) name=${name}_total ;; esac ;;
        gauge:*) ;;
        *) return 0 ;;
    esac
    # Labels sorted by key: tag keys are [A-Za-z0-9_]+, so a byte sort of
    # "key=value" lines sorts by key.
    sorted=$(for tag in "$@"; do printf '%s\n' "$tag"; done | LC_ALL=C sort -t= -k1,1)
    local nl=$'\n'
    while [ -n "$sorted" ]; do
        tag=${sorted%%"$nl"*}
        case $sorted in *"$nl"*) sorted=${sorted#*"$nl"} ;; *) sorted='' ;; esac
        key=${tag%%=*}
        val=${tag#*=}
        case $key in [0-9]*) key=_$key ;; esac
        val=${val//\\/\\\\}
        val=${val//\"/\\\"}
        labels="$labels,$key=\"$val\""
    done
    labels=${labels#,}
    _vp_rec="$name	$labels	$type	$value"
}

vigil_prom_merge() {
    local old=$1 line name labels type value
    local LC_ALL=C
    shift
    {
        # The old file's series first, then every event, in order.
        if [ "$old" != - ] && [ -f "$old" ]; then
            type=gauge
            while IFS= read -r line || [ -n "$line" ]; do
                case $line in
                    '# TYPE '*)
                        type=${line##* }
                        continue
                        ;;
                    '' | '#'*) continue ;;
                esac
                value=${line##* }
                line=${line% *}
                case $line in
                    *'{'*) name=${line%%\{*}; labels=${line#*\{}; labels=${labels%\}} ;;
                    *) name=$line; labels='' ;;
                esac
                # An old total is the starting point, not an increment.
                printf '%s\t%s\t%s\t%s\tbase\n' "$name" "$labels" "$type" "$value"
            done < "$old"
        fi
        for f in "$@"; do
            while IFS= read -r line || [ -n "$line" ]; do
                _vigil_prom_event "$line"
                [ -n "$_vp_rec" ] && printf '%s\tevent\n' "$_vp_rec"
            done < "$f"
        done
    } | awk -F '\t' '
        # Aggregate per series: a counter sums, a gauge keeps its latest value.
        {
            key = $1 "\t" $2
            if (!(key in type)) { order[++n] = key; type[key] = $3 }
            if ($3 == "counter" && $5 == "event" && (key in value)) {
                value[key] = sprintf("%.0f", value[key] + $4)
            } else {
                value[key] = $4
            }
        }
        # "-" stands for no labels: bash read collapses consecutive tabs.
        END {
            for (i = 1; i <= n; i++) {
                split(order[i], k, "\t")
                print k[1] "\t" (k[2] == "" ? "-" : k[2]) "\t" type[order[i]] "\t" value[order[i]]
            }
        }
    ' | sort -t "$(printf '\t')" -k1,1 -k2,2 | {
        local last=''
        while IFS="$(printf '\t')" read -r name labels type value; do
            if [ "$name" != "$last" ]; then
                printf '# TYPE %s %s\n' "$name" "$type"
                last=$name
            fi
            if [ "$labels" != - ]; then
                printf '%s{%s} %s\n' "$name" "$labels" "$value"
            else
                printf '%s %s\n' "$name" "$value"
            fi
        done
    }
}
