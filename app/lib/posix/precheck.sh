# shellcheck shell=bash
#
# Vigil pre-flight checks - bash 3.2 compatible.
#
# What vigil precheck prints (SPECIFICATION.md 16.3, 16.4, 6.6).
#
#   vigil_config_report
#     Pure: every parser error and validation record of the last parse, one
#     per line, with its line and message. Shared with the PowerShell twin
#     and tested by tests/conformance/report. Prints nothing when there are
#     none.
#   vigil_config_effective_report <job id>
#     Pure: a job's effective settings and where each came from (6.6).
#   vigil_precheck_report_dump
#     Pure, for the conformance suite: vigil_config_report, then the
#     effective report of every valid job when the configuration is not
#     rejected.
#   vigil_precheck <root> [<job id>]
#     Loads the configuration and checks, without starting or changing
#     anything, that everything a run needs is there (16.4). Returns 0 when
#     nothing failed (warnings are allowed), 1 otherwise. Secrets are
#     resolved and thrown away: only their references are printed.
#
# Requires config.sh, validate.sh, effective.sh, command.sh, secrets.sh,
# stores.sh and worker.sh.

# One record: ERROR, INVALID or WARN, its line, message and code.
_vigil_pc_record() {
    local where
    if [ "$3" -gt 0 ] 2>/dev/null; then where="line $3: "; else where=''; fi
    if [ "$1" = INVALID ]; then
        printf 'INVALID  job.%s, %s%s (%s)\n' "$2" "$where" "$5" "$4"
    else
        printf '%-8s %s%s (%s)\n' "$1" "$where" "$5" "$4"
    fi
}

# In file order: by line, then as found. Each record is keyed by both
# before sorting, and the keys are cut off after.
vigil_config_report() {
    local i=0 n=0 e line code
    {
        while [ "$i" -lt "${#VIGIL_CFG_ERRORS[@]}" ]; do
            e=${VIGIL_CFG_ERRORS[$i]}
            line=${e%%	*}
            e=${e#*	}
            code=${e%%	*}
            printf '%s\t%s\t' "${line:-0}" "$n"
            _vigil_pc_record ERROR '' "$line" "$code" "${e#*	}"
            i=$((i + 1))
            n=$((n + 1))
        done
        i=0
        while [ "$i" -lt "${#VIGIL_VAL_KIND[@]}" ]; do
            printf '%s\t%s\t' "${VIGIL_VAL_LINE[$i]:-0}" "$n"
            _vigil_pc_record "${VIGIL_VAL_KIND[$i]}" "${VIGIL_VAL_JOB[$i]}" "${VIGIL_VAL_LINE[$i]}" "${VIGIL_VAL_CODE[$i]}" "${VIGIL_VAL_MSG[$i]}"
            i=$((i + 1))
            n=$((n + 1))
        done
    } | LC_ALL=C sort -t "$(printf '\t')" -k1,1n -k2,2n | cut -f3-
}

vigil_config_effective_report() {
    local i=0 value
    vigil_config_effective "$1"
    printf 'job.%s\n' "$1"
    while [ "$i" -lt "${#VIGIL_EFF_KEY[@]}" ]; do
        value=${VIGIL_EFF_VALUE[$i]}
        [ -n "$value" ] || value=none
        printf '  %-17s = %-22s (%s)\n' "${VIGIL_EFF_KEY[$i]}" "$value" "${VIGIL_EFF_SOURCE[$i]}"
        i=$((i + 1))
    done
}

# Whether the configuration was rejected: any parser error or ERROR record.
_vigil_pc_rejected() {
    local i=0
    [ "${#VIGIL_CFG_ERRORS[@]}" -eq 0 ] || return 0
    while [ "$i" -lt "${#VIGIL_VAL_KIND[@]}" ]; do
        [ "${VIGIL_VAL_KIND[$i]}" = ERROR ] && return 0
        i=$((i + 1))
    done
    return 1
}

# Whether job $1 is INVALID.
_vigil_pc_invalid() {
    local i=0
    while [ "$i" -lt "${#VIGIL_VAL_KIND[@]}" ]; do
        [ "${VIGIL_VAL_KIND[$i]}" = INVALID ] && [ "${VIGIL_VAL_JOB[$i]}" = "$1" ] && return 0
        i=$((i + 1))
    done
    return 1
}

# The ids of all job sections, in file order, in _pc_jobs.
_vigil_pc_jobs() {
    local s=0
    _pc_jobs=()
    while [ "$s" -lt "${#VIGIL_CFG_SEC_NAME[@]}" ]; do
        case ${VIGIL_CFG_SEC_NAME[$s]} in
            job.*) _pc_jobs[${#_pc_jobs[@]}]=${VIGIL_CFG_SEC_NAME[$s]#job.} ;;
        esac
        s=$((s + 1))
    done
}

vigil_precheck_report_dump() {
    local id
    vigil_config_report
    _vigil_pc_rejected && return 0
    _vigil_pc_jobs
    for id in ${_pc_jobs[@]+"${_pc_jobs[@]}"}; do
        _vigil_pc_invalid "$id" || vigil_config_effective_report "$id"
    done
}

_vigil_pc_ok() { printf '  ok    %s\n' "$1"; }
_vigil_pc_fail() { printf '  FAIL  %s\n' "$1"; _pc_failed=$((_pc_failed + 1)); }

# Whether a program can be started: a path must be an executable file, a
# bare name must be on the PATH. Sets _pc_why when it cannot.
_vigil_pc_program() {
    _pc_why=''
    case $1 in
        */*)
            if [ ! -e "$1" ]; then _pc_why="not found: $1"
            elif [ ! -x "$1" ] || [ -d "$1" ]; then _pc_why="not executable: $1"
            fi
            ;;
        *) command -v "$1" > /dev/null 2>&1 || _pc_why="not found: $1" ;;
    esac
    [ -z "$_pc_why" ]
}

# Everything one run of job $1 needs, as the worker checks it (4.3).
_vigil_pc_job() {
    local id=$1 i ref name before=$_pc_failed provided=' '
    vigil_job_command "$id" posix "$_vw_root"
    if [ -n "$VIGIL_CMD_ERROR" ]; then
        _vigil_pc_fail "job.$id: $VIGIL_CMD_MESSAGE"
        return
    fi
    [ -d "$VIGIL_CMD_CWD" ] || _vigil_pc_fail "job.$id: working directory not found: $VIGIL_CMD_CWD"
    _vigil_pc_program "$VIGIL_CMD_PROGRAM" || _vigil_pc_fail "job.$id: $_pc_why"
    _vigil_wk_get "job.$id" file ''
    _vigil_cmd_path "$_vw_value" posix "$_vw_root"
    [ -n "${VIGIL_CMD_FILE-}" ] && _vc_path=$VIGIL_CMD_FILE
    [ -f "$_vc_path" ] || _vigil_pc_fail "job.$id: file not found: $_vc_path"
    vigil_config_effective "$id"
    i=0
    while [ "$i" -lt "${#VIGIL_EFF_KEY[@]}" ]; do
        if [ "${VIGIL_EFF_KEY[$i]}" = secret ]; then
            name=${VIGIL_EFF_VALUE[$i]%%=*}
            ref=${VIGIL_EFF_VALUE[$i]#*=}
            if vigil_secret_resolve "$_vw_root" "$ref"; then
                provided="$provided$name "
            else
                _vigil_pc_fail "job.$id: secret $ref unavailable: $VIGIL_SECRET_WHY"
            fi
            VIGIL_SECRET_VALUE=''
        fi
        i=$((i + 1))
    done
    i=0
    while [ "$i" -lt "${#VIGIL_EFF_KEY[@]}" ]; do
        if [ "${VIGIL_EFF_KEY[$i]}" = require_env ]; then
            name=${VIGIL_EFF_VALUE[$i]}
            case $provided in *" $name "*) ;; *)
                eval "[ -n \"\${$name+set}\" ]" || _vigil_pc_fail "job.$id: missing environment variable $name" ;;
            esac
        fi
        i=$((i + 1))
    done
    [ "$_pc_failed" -eq "$before" ] && _vigil_pc_ok "job.$id"
}

# What each source of the parsed configuration needs on this host: its
# client program, or for a local source its directory.
_vigil_pc_sources() {
    local s=0 name dir
    while [ "$s" -lt "${#VIGIL_CFG_SEC_NAME[@]}" ]; do
        name=${VIGIL_CFG_SEC_NAME[$s]}
        s=$((s + 1))
        case $name in source.*) ;; *) continue ;; esac
        _vigil_wk_get "$name" type ''
        case $_vw_value in
            git | sftp)
                if command -v "$_vw_value" > /dev/null 2>&1; then _vigil_pc_ok "$name: $_vw_value"
                else _vigil_pc_fail "$name: $_vw_value not found"
                fi
                ;;
            https)
                if command -v curl > /dev/null 2>&1; then _vigil_pc_ok "$name: curl"
                else _vigil_pc_fail "$name: curl not found"
                fi
                ;;
            local)
                _vigil_wk_get "$name" path ''
                dir=$_vw_value
                case $dir in /*) ;; *) dir="$_vw_root/$dir" ;; esac
                if [ -d "$dir" ]; then _vigil_pc_ok "$name: $dir"
                else _vigil_pc_fail "$name: not a directory: $dir"
                fi
                ;;
        esac
    done
}

# With sources (16.5): what each source needs, then the jobs. A pointer
# file's jobs are those of the active configuration, once fetched; a local
# file's are its own, each script from a source as the active record has it
# cached. Nothing is fetched.
_vigil_pc_fetch() {
    local only=$1 id src remote
    _vigil_pc_sources
    _vigil_wk_get vigil config_source ''
    remote=$_vw_value
    if vigil_active_read "$2"; then
        _vigil_pc_ok "configuration revision $VIGIL_ACT_REVISION is active ($VIGIL_ACT_ORIGIN)"
        if [ -n "$remote" ]; then
            vigil_config_parse "$VIGIL_ACT_CONFIG"
            vigil_config_validate
            _vigil_pc_sources
        fi
    elif [ -n "$remote" ]; then
        _vigil_pc_ok "configuration: not fetched yet; the supervisor fetches it from source.$remote"
        return 0
    fi
    _vigil_pc_jobs
    for id in ${_pc_jobs[@]+"${_pc_jobs[@]}"}; do
        [ -z "$only" ] || [ "$id" = "$only" ] || continue
        _vigil_pc_invalid "$id" && continue
        _vigil_wk_get "job.$id" source ''
        if [ -z "$_vw_value" ]; then
            _vigil_pc_job "$id"
            continue
        fi
        src=$_vw_value
        _vigil_wk_get "job.$id" file ''
        if vigil_active_script "$src" "$_vw_value" && [ -f "$_va_path" ]; then
            VIGIL_CMD_FILE=$_va_path
            _vigil_pc_job "$id"
            VIGIL_CMD_FILE=''
        else
            _vigil_pc_ok "job.$id: its script is fetched from source.$src when Vigil runs"
        fi
    done
}

# A directory Vigil writes to: it, or the nearest folder above it that
# exists, must be writable. Nothing is created.
_vigil_pc_dir() {
    local d=$2
    while [ ! -d "$d" ]; do
        case $d in */*) d=${d%/*}; [ -n "$d" ] || d=/ ;; *) break ;; esac
    done
    if [ -d "$d" ] && [ -w "$d" ]; then
        _vigil_pc_ok "$1: $2"
    else
        _vigil_pc_fail "$1: not writable: $d"
    fi
}

vigil_precheck() {
    local only=${2-} id s i end value sec statedir
    local LC_ALL=C
    local -a _pc_jobs
    _pc_failed=0
    _vw_root=$1
    _vw_job=-
    vigil_config_parse "$_vw_root/config/vigil.config"
    vigil_config_validate

    local errors=0 invalid=0 warnings=0
    errors=${#VIGIL_CFG_ERRORS[@]}
    i=0
    while [ "$i" -lt "${#VIGIL_VAL_KIND[@]}" ]; do
        case ${VIGIL_VAL_KIND[$i]} in
            ERROR) errors=$((errors + 1)) ;;
            INVALID) invalid=$((invalid + 1)) ;;
            WARN) warnings=$((warnings + 1)) ;;
        esac
        i=$((i + 1))
    done
    printf 'Configuration %s\n' "$_vw_root/config/vigil.config"
    if [ $((errors + invalid + warnings)) -eq 0 ]; then
        printf '  no problems\n'
    else
        vigil_config_report | sed 's/^/  /'
    fi
    _pc_failed=$((errors + invalid))
    if [ "$errors" -gt 0 ]; then
        printf '\nprecheck failed: the configuration is rejected; nothing else was checked\n'
        return 1
    fi

    if [ -n "$only" ]; then
        vigil_config_section "job.$only"
        if [ "$VIGIL_CFG_SEC" -lt 0 ]; then
            printf '\nprecheck failed: no job %s in the configuration\n' "$only"
            return 1
        fi
        printf '\n'
        if _vigil_pc_invalid "$only"; then
            printf 'job.%s is INVALID; its effective settings are not shown\n' "$only"
        else
            vigil_config_effective_report "$only"
        fi
    fi

    printf '\nChecks\n'
    # The state directory is always this file's (6.8).
    _vigil_wk_dir vigil state_dir state
    statedir=$_vw_dir
    if vigil_fetch_mode; then
        _vigil_pc_fetch "$only" "$statedir"
    else
        _vigil_pc_jobs
        for id in ${_pc_jobs[@]+"${_pc_jobs[@]}"}; do
            [ -z "$only" ] || [ "$id" = "$only" ] || continue
            _vigil_pc_invalid "$id" || _vigil_pc_job "$id"
        done
    fi

    # Credentials of backends and secret stores: resolved, never shown.
    s=0
    while [ "$s" -lt "${#VIGIL_CFG_SEC_NAME[@]}" ]; do
        sec=${VIGIL_CFG_SEC_NAME[$s]}
        case $sec in
            backend.* | secret_store.* | source.* | log_destination.*)
                i=${VIGIL_CFG_SEC_FIRST[$s]}
                end=$((i + VIGIL_CFG_SEC_COUNT[s]))
                while [ "$i" -lt "$end" ]; do
                    value=${VIGIL_CFG_VALUE[$i]}
                    case $value in
                        env:* | secret:* | store:*)
                            if vigil_secret_resolve "$_vw_root" "$value"; then
                                _vigil_pc_ok "$sec: ${VIGIL_CFG_KEY[$i]} $value"
                            else
                                _vigil_pc_fail "$sec: ${VIGIL_CFG_KEY[$i]} $value unavailable: $VIGIL_SECRET_WHY"
                            fi
                            VIGIL_SECRET_VALUE=''
                            ;;
                    esac
                    i=$((i + 1))
                done
                # Which client a cloud store uses: its CLI, or Vigil's own.
                case $sec in
                    secret_store.*)
                        _vigil_val_first "$s" type
                        case $_vv_first in
                            azure_keyvault | aws_secrets_manager | gcp_secret_manager)
                                if vigil_store_client_report "$_vw_root" "$s" "$_vv_first"; then
                                    _vigil_pc_ok "$sec: $VIGIL_STORE_CLIENT"
                                else
                                    _vigil_pc_fail "$sec: $VIGIL_STORE_CLIENT"
                                fi
                                ;;
                        esac
                        ;;
                esac
                ;;
        esac
        s=$((s + 1))
    done

    _vigil_pc_dir 'state directory' "$statedir"
    _vigil_wk_dir log dir logs
    _vigil_pc_dir 'log directory' "$_vw_dir"
    _vigil_wk_dir spool dir spool
    _vigil_pc_dir 'spool directory' "$_vw_dir"
    [ -z "${VIGIL_FAULT-}" ] || _vigil_pc_fail 'VIGIL_FAULT is set: fault injection is for tests only (22.4.1)'
    [ -z "${VIGIL_TEST_IMDS-}" ] || _vigil_pc_fail 'VIGIL_TEST_IMDS is set: the metadata endpoint override is for tests only (22.4.2)'
    [ -z "${VIGIL_TEST_SSH_CONFIG-}" ] || _vigil_pc_fail 'VIGIL_TEST_SSH_CONFIG is set: the ssh configuration override is for tests only (22.4.3)'
    [ -z "${VIGIL_TEST_RELEASE_URL-}" ] || _vigil_pc_fail 'VIGIL_TEST_RELEASE_URL is set: the release server override is for tests only (22.4.4)'

    printf '\n'
    if [ "$_pc_failed" -gt 0 ]; then
        printf 'precheck failed: %d problem(s)\n' "$_pc_failed"
        return 1
    fi
    if [ "$warnings" -gt 0 ]; then
        printf 'precheck passed with %d warning(s)\n' "$warnings"
    else
        printf 'precheck passed\n'
    fi
}
