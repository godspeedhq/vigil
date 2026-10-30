# shellcheck shell=bash
#
# Vigil effective job settings - bash 3.2 compatible.
#
# Resolves a job's settings from the job, [defaults], the global sections
# and built-in defaults, following SPECIFICATION.md 6.6. Assumes the config
# passed validation. Must produce exactly the same result as Effective.ps1 -
# tests/conformance/effective holds the shared cases.
#
# Result, in a fixed key order, as parallel arrays:
#   VIGIL_EFF_KEY[i]  VIGIL_EFF_VALUE[i]  VIGIL_EFF_SOURCE[i]
# Source is one of: job, defaults, scheduler, log, tags, runners, runner, source,
# built-in. List keys (arg, tag, env, require_env) produce one row per item.
# List values (run_at, run_on_days, backends) are normalised to "a, b".
#
# Requires config.sh.

_vigil_eff_add() {
    local i=${#VIGIL_EFF_KEY[@]}
    VIGIL_EFF_KEY[$i]=$1
    VIGIL_EFF_VALUE[$i]=$2
    VIGIL_EFF_SOURCE[$i]=$3
}

# Index of a section in VIGIL_CFG_SEC_NAME, or -1. Result in _ve_sec.
_vigil_eff_section() {
    vigil_config_section "$1"
    _ve_sec=$VIGIL_CFG_SEC
}

# The default backend list - every backend not disabled, in file order -
# computed once per parse. Result in _ve_all_backends.
_vigil_eff_prepare() {
    local j=0 item
    [ "${_ve_generation:-}" = "$VIGIL_CFG_GENERATION" ] && return 0
    _ve_all_backends=''
    while [ "$j" -lt "${#VIGIL_CFG_SEC_NAME[@]}" ]; do
        item=${VIGIL_CFG_SEC_NAME[$j]}
        j=$((j + 1))
        case $item in
            backend.*) ;;
            *) continue ;;
        esac
        _vigil_eff_get "$item" enabled
        [ "$_ve_value" = false ] && continue
        if [ -n "$_ve_all_backends" ]; then
            _ve_all_backends="$_ve_all_backends, ${item#backend.}"
        else
            _ve_all_backends=${item#backend.}
        fi
    done
    _ve_generation=$VIGIL_CFG_GENERATION
}

# First value of a key in a section. Sets _ve_found (0/1) and _ve_value.
_vigil_eff_get() {
    local i end
    _ve_found=0
    _ve_value=''
    _vigil_eff_section "$1"
    [ "$_ve_sec" -ge 0 ] || return 0
    i=${VIGIL_CFG_SEC_FIRST[$_ve_sec]}
    end=$((i + VIGIL_CFG_SEC_COUNT[$_ve_sec]))
    while [ "$i" -lt "$end" ]; do
        if [ "${VIGIL_CFG_KEY[$i]}" = "$2" ]; then
            _ve_found=1
            _ve_value=${VIGIL_CFG_VALUE[$i]}
            return 0
        fi
        i=$((i + 1))
    done
}

# Every value of a key in a section, in file order, into _ve_values.
_vigil_eff_all() {
    local i end
    _ve_values=()
    _vigil_eff_section "$1"
    [ "$_ve_sec" -ge 0 ] || return 0
    i=${VIGIL_CFG_SEC_FIRST[$_ve_sec]}
    end=$((i + VIGIL_CFG_SEC_COUNT[$_ve_sec]))
    while [ "$i" -lt "$end" ]; do
        if [ "${VIGIL_CFG_KEY[$i]}" = "$2" ]; then
            _ve_values[${#_ve_values[@]}]=${VIGIL_CFG_VALUE[$i]}
        fi
        i=$((i + 1))
    done
}

# Normalises a comma-separated list to "a, b". Result in _ve_list.
_vigil_eff_list() {
    local rest=$1
    _ve_list=''
    while :; do
        _vigil_cfg_trim "${rest%%,*}"
        if [ -n "$_ve_list" ]; then
            _ve_list="$_ve_list, $_vigil_cfg_trimmed"
        else
            _ve_list=$_vigil_cfg_trimmed
        fi
        case $rest in
            *,*) rest=${rest#*,} ;;
            *) break ;;
        esac
    done
}

# Resolves one single-valued key: the job, then each "section:key" given,
# then the built-in value. Adds one row.
#   _vigil_eff_single <job section> <key> <built-in> [<section>:<key> ...]
_vigil_eff_single() {
    local job=$1 key=$2 builtin=$3 layer
    shift 3
    _vigil_eff_get "$job" "$key"
    if [ "$_ve_found" -eq 1 ]; then
        _vigil_eff_add "$key" "$_ve_value" job
        return
    fi
    for layer in ${1+"$@"}; do
        _vigil_eff_get "${layer%%:*}" "${layer#*:}"
        if [ "$_ve_found" -eq 1 ]; then
            _vigil_eff_add "$key" "$_ve_value" "${layer%%:*}"
            return
        fi
    done
    _vigil_eff_add "$key" "$builtin" built-in
}

# Merges NAME=value pairs: global rows first (a job value with the same name
# replaces it in place), then the job's other pairs.
#   _vigil_eff_pairs <key> <global source> <job section> <global section> <global key|*>
# A global key of "*" reads every key of the section as name = value ([tags]).
_vigil_eff_pairs() {
    local key=$1 gsource=$2 job=$3 gsec=$4 gkey=$5
    local names=() values=() jnames=() jvalues=() i j end found
    if [ "$gkey" = '*' ]; then
        _vigil_eff_section "$gsec"
        if [ "$_ve_sec" -ge 0 ]; then
            i=${VIGIL_CFG_SEC_FIRST[$_ve_sec]}
            end=$((i + VIGIL_CFG_SEC_COUNT[$_ve_sec]))
            while [ "$i" -lt "$end" ]; do
                names[${#names[@]}]=${VIGIL_CFG_KEY[$i]}
                values[${#values[@]}]=${VIGIL_CFG_VALUE[$i]}
                i=$((i + 1))
            done
        fi
    elif [ -n "$gsec" ]; then
        _vigil_eff_all "$gsec" "$gkey"
        for i in ${_ve_values[@]+"${_ve_values[@]}"}; do
            names[${#names[@]}]=${i%%=*}
            values[${#values[@]}]=${i#*=}
        done
    fi
    _vigil_eff_all "$job" "$key"
    for i in ${_ve_values[@]+"${_ve_values[@]}"}; do
        jnames[${#jnames[@]}]=${i%%=*}
        jvalues[${#jvalues[@]}]=${i#*=}
    done

    i=0
    while [ "$i" -lt "${#names[@]}" ]; do
        found=-1
        j=0
        while [ "$j" -lt "${#jnames[@]}" ]; do
            if [ "${jnames[$j]}" = "${names[$i]}" ]; then
                found=$j
                break
            fi
            j=$((j + 1))
        done
        if [ "$found" -ge 0 ]; then
            _vigil_eff_add "$key" "${names[$i]}=${jvalues[$found]}" job
        else
            _vigil_eff_add "$key" "${names[$i]}=${values[$i]}" "$gsource"
        fi
        i=$((i + 1))
    done
    j=0
    while [ "$j" -lt "${#jnames[@]}" ]; do
        found=0
        for i in ${names[@]+"${names[@]}"}; do
            if [ "$i" = "${jnames[$j]}" ]; then
                found=1
                break
            fi
        done
        if [ "$found" -eq 0 ]; then
            _vigil_eff_add "$key" "${jnames[$j]}=${jvalues[$j]}" job
        fi
        j=$((j + 1))
    done
}

# vigil_config_effective <job id>
vigil_config_effective() {
    local id=$1 job="job.$1" runner='' value ext seen nl=$'\n' item j
    local LC_ALL=C
    VIGIL_EFF_KEY=()
    VIGIL_EFF_VALUE=()
    VIGIL_EFF_SOURCE=()

    _vigil_eff_get "$job" file
    local file=$_ve_value
    _vigil_eff_add file "$file" job

    # A fetched script: its source, the source's ref (git) and the job's
    # digest. Rows appear only when set.
    _vigil_eff_get "$job" source
    if [ "$_ve_found" -eq 1 ]; then
        value=$_ve_value
        _vigil_eff_add source "$value" job
        _vigil_eff_get "source.$value" ref
        if [ "$_ve_found" -eq 1 ]; then _vigil_eff_add ref "$_ve_value" source; fi
        _vigil_eff_get "$job" sha256
        if [ "$_ve_found" -eq 1 ]; then _vigil_eff_add sha256 "$_ve_value" job; fi
    fi

    # Runner: the job's key, else the file extension in [runners], else none
    # (the file is executed directly).
    _vigil_eff_get "$job" runner
    if [ "$_ve_found" -eq 1 ]; then
        runner=$_ve_value
        _vigil_eff_add runner "$runner" job
    else
        value=${file##*/}
        value=${value##*\\}
        case $value in
            *.*) _vigil_lower "${value##*.}"; ext=.$_vigil_lowered ;;
            *) ext='' ;;
        esac
        _ve_found=0
        if [ -n "$ext" ]; then
            _vigil_eff_get runners "$ext"
        fi
        if [ "$_ve_found" -eq 1 ]; then
            runner=$_ve_value
            _vigil_eff_add runner "$runner" runners
        else
            _vigil_eff_add runner '' built-in
        fi
    fi

    _vigil_eff_all "$job" arg
    for value in ${_ve_values[@]+"${_ve_values[@]}"}; do
        _vigil_eff_add arg "$value" job
    done

    _vigil_eff_single "$job" metric_name "$id"

    _vigil_eff_get "$job" run_every
    if [ "$_ve_found" -eq 1 ]; then
        _vigil_eff_add run_every "$_ve_value" job
    fi
    _vigil_eff_get "$job" run_at
    if [ "$_ve_found" -eq 1 ]; then
        _vigil_eff_list "$_ve_value"
        _vigil_eff_add run_at "$_ve_list" job
    fi
    _vigil_eff_get "$job" run_on_days
    if [ "$_ve_found" -eq 1 ]; then
        _vigil_lower "$_ve_value"
        _vigil_eff_list "$_vigil_lowered"
        _vigil_eff_add run_on_days "$_ve_list" job
    fi

    _vigil_eff_single "$job" max_runtime '' defaults:max_runtime
    _vigil_eff_single "$job" grace 30s defaults:grace
    _vigil_eff_single "$job" overlap skip defaults:overlap
    _vigil_eff_single "$job" exit_codes standard defaults:exit_codes
    _vigil_eff_single "$job" enabled true defaults:enabled
    _vigil_eff_single "$job" on_uncertain wait defaults:on_uncertain

    # Backends: an explicit list replaces the default of every enabled backend.
    _vigil_eff_get "$job" backends
    if [ "$_ve_found" -eq 1 ]; then
        _vigil_eff_list "$_ve_value"
        _vigil_eff_add backends "$_ve_list" job
    else
        _vigil_eff_get defaults backends
        if [ "$_ve_found" -eq 1 ]; then
            _vigil_eff_list "$_ve_value"
            _vigil_eff_add backends "$_ve_list" defaults
        else
            _vigil_eff_prepare
            _vigil_eff_add backends "$_ve_all_backends" built-in
        fi
    fi

    _vigil_eff_single "$job" late_start_window 15m defaults:late_start_window scheduler:late_start_window
    _vigil_eff_single "$job" log_retain_days 7 defaults:log_retain_days log:retain_days
    _vigil_eff_single "$job" working_dir . defaults:working_dir

    _vigil_eff_pairs tag tags "$job" tags '*'
    if [ -n "$runner" ]; then
        _vigil_eff_pairs env runner "$job" "runner.$runner" env
    else
        _vigil_eff_pairs env runner "$job" '' ''
    fi

    # require_env: the runner's names, then the job's, each name once.
    seen=$nl
    if [ -n "$runner" ]; then
        _vigil_eff_all "runner.$runner" require_env
        for value in ${_ve_values[@]+"${_ve_values[@]}"}; do
            _vigil_eff_split "$value"
            for item in ${_ve_items[@]+"${_ve_items[@]}"}; do
                case $seen in *$nl"$item"$nl*) continue ;; esac
                seen="$seen$item$nl"
                _vigil_eff_add require_env "$item" runner
            done
        done
    fi
    _vigil_eff_all "$job" require_env
    for value in ${_ve_values[@]+"${_ve_values[@]}"}; do
        _vigil_eff_split "$value"
        for item in ${_ve_items[@]+"${_ve_items[@]}"}; do
            case $seen in *$nl"$item"$nl*) continue ;; esac
            seen="$seen$item$nl"
            _vigil_eff_add require_env "$item" job
        done
    done
}

# Splits a comma-separated value into _ve_items, each item trimmed.
_vigil_eff_split() {
    local rest=$1
    _ve_items=()
    while :; do
        _vigil_cfg_trim "${rest%%,*}"
        _ve_items[${#_ve_items[@]}]=$_vigil_cfg_trimmed
        case $rest in
            *,*) rest=${rest#*,} ;;
            *) break ;;
        esac
    done
}

# vigil_config_effective_dump
# Prints the effective settings of every job that is not INVALID (requires
# vigil_config_validate to have run), one row per line:
#   <job> TAB <key> TAB <value> TAB <source>
# A rejected configuration (any ERROR record) prints nothing.
vigil_config_effective_dump() {
    local s=0 i name id
    i=0
    while [ "$i" -lt "${#VIGIL_VAL_KIND[@]}" ]; do
        [ "${VIGIL_VAL_KIND[$i]}" = ERROR ] && return 0
        i=$((i + 1))
    done
    [ "${#VIGIL_CFG_ERRORS[@]}" -eq 0 ] || return 0

    while [ "$s" -lt "${#VIGIL_CFG_SEC_NAME[@]}" ]; do
        name=${VIGIL_CFG_SEC_NAME[$s]}
        s=$((s + 1))
        case $name in
            job.*) id=${name#job.} ;;
            *) continue ;;
        esac
        i=0
        while [ "$i" -lt "${#VIGIL_VAL_KIND[@]}" ]; do
            if [ "${VIGIL_VAL_KIND[$i]}" = INVALID ] && [ "${VIGIL_VAL_JOB[$i]}" = "$id" ]; then
                continue 2
            fi
            i=$((i + 1))
        done
        vigil_config_effective "$id"
        i=0
        while [ "$i" -lt "${#VIGIL_EFF_KEY[@]}" ]; do
            printf '%s\t%s\t%s\t%s\n' "$id" "${VIGIL_EFF_KEY[$i]}" "${VIGIL_EFF_VALUE[$i]}" "${VIGIL_EFF_SOURCE[$i]}"
            i=$((i + 1))
        done
    done
}
