# shellcheck shell=bash
#
# Vigil configuration validation - bash 3.2 compatible.
#
# Checks the result of vigil_config_parse against SPECIFICATION.md 6 and
# 16.3. It is a pure function of the parsed entries: it never touches the
# filesystem or the environment (pre-flight does that). It must produce
# exactly the same records as Validate.ps1 - tests/conformance/validate holds
# the shared cases.
#
# Records, in order, as parallel arrays:
#   VIGIL_VAL_KIND[i]  ERROR (whole config rejected), INVALID (only that job
#                      is skipped) or WARN
#   VIGIL_VAL_JOB[i]   the job id for INVALID, otherwise empty
#   VIGIL_VAL_LINE[i]  line number (a section header line for missing keys)
#   VIGIL_VAL_CODE[i]  error code
#   VIGIL_VAL_MSG[i]   message; never contains a credential value
#
# Order: sections in file order; within a section its entries in file order,
# then the section-level checks. At most one record per entry.
#
# Requires config.sh. bash 3.2: no associative arrays - name sets are
# newline-delimited strings, matched with case.

VIGIL_BACKEND_TYPES=$'\nfile\ndatadog\notel\nprometheus\nvictoriametrics\ninfluxdb\nsplunk\ngraphite\nstatsd\nelasticsearch\nopensearch\nazuremonitor\ncloudwatch\ngcp\nnewrelic\ndynatrace\nwebhook\n'
VIGIL_RESERVED_TAGS=$'\nhost\nos\ninstance\njob\nlabel\nuom\nexit_code\n'

_vigil_val_re_dur='^[0-9]{1,6}[smhd]$'
_vigil_val_re_zero_dur='^0+[smhd]$'
_vigil_val_re_int='^[0-9]{1,6}$'
_vigil_val_re_zero='^0+$'
_vigil_val_re_name='^[A-Za-z0-9_.-]+$'
_vigil_val_re_metric='^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)*$'
_vigil_val_re_time='^([01][0-9]|2[0-3]):[0-5][0-9]$'
_vigil_val_re_code='^([0-9]{1,3})(-([0-9]{1,3}))?$'
_vigil_val_re_envname='^[A-Za-z_][A-Za-z0-9_]*$'
_vigil_val_re_envpair='^([A-Za-z_][A-Za-z0-9_]*)=(.*)$'
_vigil_val_re_tagkey='^[a-z0-9_]+$'
_vigil_val_re_tagvalue='^[^[:space:]]+$'
_vigil_val_re_tagpair='^([a-z0-9_]+)=([^[:space:]]+)$'
_vigil_val_re_cred='^env:([A-Za-z_][A-Za-z0-9_]*)$'
_vigil_val_re_ext='^\.[a-z0-9_]+$'
_vigil_val_re_scp='^([A-Za-z0-9._-]+@)?[A-Za-z0-9.-]{2,}:.+$'
_vigil_val_re_sha256='^[0-9A-Fa-f]{64}$'

_vigil_val_add() {
    local i=${#VIGIL_VAL_KIND[@]}
    VIGIL_VAL_KIND[$i]=$1
    VIGIL_VAL_JOB[$i]=$2
    VIGIL_VAL_LINE[$i]=$3
    VIGIL_VAL_CODE[$i]=$4
    VIGIL_VAL_MSG[$i]=$5
}

# Reports against the current section: INVALID inside a job, ERROR elsewhere.
_vigil_val_report() {
    if [ -n "$_vv_job" ]; then
        _vigil_val_add INVALID "$_vv_job" "$1" "$2" "$3"
    else
        _vigil_val_add ERROR '' "$1" "$2" "$3"
    fi
}

# Splits a comma-separated value into _vv_items, each item trimmed.
_vigil_val_split() {
    local rest=$1
    _vv_items=()
    while :; do
        _vigil_cfg_trim "${rest%%,*}"
        _vv_items[${#_vv_items[@]}]=$_vigil_cfg_trimmed
        case $rest in
            *,*) rest=${rest#*,} ;;
            *) break ;;
        esac
    done
}

# Sets _vv_type and _vv_list (1 = repeatable) for a key in a section kind.
# An empty _vv_type means the key is unknown there.
_vigil_val_keytype() {
    _vv_type=''
    _vv_list=0
    case $1:$2 in
        vigil:config_source) _vv_type=source_ref ;;
        vigil:config_file) _vv_type=srcpath ;;
        vigil:instance) _vv_type=name ;;
        vigil:state_dir) _vv_type=path ;;
        vigil:max_concurrent) _vv_type=int1 ;;
        scheduler:tick) _vv_type=dur ;;
        scheduler:late_start_window) _vv_type=dur0 ;;
        scheduler:max_pending) _vv_type=int ;;
        log:dir) _vv_type=path ;;
        log:stdout) _vv_type=bool ;;
        log:retain_days | log:max_file_mb) _vv_type=int1 ;;
        spool:dir) _vv_type=path ;;
        spool:max_mb) _vv_type=int1 ;;
        spool:when_full) _vv_type=when_full ;;
        runner:command) _vv_type=path ;;
        runner:arg) _vv_type=arg; _vv_list=1 ;;
        runner:env) _vv_type=envpair; _vv_list=1 ;;
        runner:require_env) _vv_type=envnames; _vv_list=1 ;;
        backend:type) _vv_type=backend_type ;;
        backend:enabled) _vv_type=bool ;;
        backend:timeout) _vv_type=dur ;;
        backend:username | backend:password | backend:token | backend:api_key | \
        backend:api_token | backend:api_key_id | backend:header_value | \
        backend:access_key_id | backend:client_id | backend:tenant_id | \
        backend:*_secret | backend:*_key | backend:*_token | backend:*_password)
            _vv_type=credential ;;
        backend:*) _vv_type=text ;;
        source:type) _vv_type=source_type ;;
        source:path) _vv_type=path ;;
        source:url) _vv_type=url ;;
        source:host | source:user | source:ref | source:header_name) _vv_type=text ;;
        source:port) _vv_type=port ;;
        source:check_every | source:timeout) _vv_type=dur ;;
        source:header_value) _vv_type=credential ;;
        defaults:file | defaults:source | defaults:sha256 | \
        defaults:arg | defaults:metric_name | defaults:run_every | \
        defaults:run_at | defaults:run_on_days | defaults:runner | defaults:tag | \
        defaults:env | defaults:require_env)
            _vv_type=job_only ;;
        job:file)
            # Inside a source, file is a relative path in that source.
            if [ -n "$_vv_jsource" ]; then _vv_type=srcpath; else _vv_type=path; fi
            ;;
        job:source) _vv_type=source_ref ;;
        job:sha256) _vv_type=sha256 ;;
        job:* | defaults:*)
            case $2 in
                file | working_dir) _vv_type=path ;;
                runner) _vv_type=runner_ref ;;
                arg) _vv_type=arg; _vv_list=1 ;;
                metric_name) _vv_type=metric ;;
                run_every | max_runtime) _vv_type=dur ;;
                run_at) _vv_type=times ;;
                run_on_days) _vv_type=days ;;
                grace | late_start_window) _vv_type=dur0 ;;
                overlap) _vv_type=overlap ;;
                exit_codes) _vv_type=exit_codes ;;
                enabled) _vv_type=bool ;;
                on_uncertain) _vv_type=on_uncertain ;;
                backends) _vv_type=backend_refs ;;
                tag) _vv_type=tagpair; _vv_list=1 ;;
                env) _vv_type=envpair; _vv_list=1 ;;
                require_env) _vv_type=envnames; _vv_list=1 ;;
                log_retain_days) _vv_type=int1 ;;
            esac
            ;;
    esac
}

# Whether key $2 applies to a source of type $1 (spec 6.9).
_vigil_val_source_key() {
    case $2 in
        type | check_every | timeout) return 0 ;;
    esac
    case $1:$2 in
        local:path | git:url | git:ref | https:url | https:header_name | https:header_value | \
        sftp:host | sftp:port | sftp:user | sftp:path) return 0 ;;
    esac
    return 1
}

# The type of source $1, or empty when it is not defined or its type is not
# valid. Sets _vv_found (1 when the source is defined) and _vv_srctype.
_vigil_val_source_type() {
    local i=0
    _vv_found=0
    _vv_srctype=''
    while [ "$i" -lt "${#_vv_src_names[@]}" ]; do
        if [ "${_vv_src_names[$i]}" = "$1" ]; then
            _vv_found=1
            _vv_srctype=${_vv_src_types[$i]}
            return 0
        fi
        i=$((i + 1))
    done
}

# The first value of key $2 in section index $1, or empty. Result in _vv_first.
_vigil_val_first() {
    local i=${VIGIL_CFG_SEC_FIRST[$1]} end
    end=$((i + VIGIL_CFG_SEC_COUNT[$1]))
    _vv_first=''
    while [ "$i" -lt "$end" ]; do
        if [ "${VIGIL_CFG_KEY[$i]}" = "$2" ]; then
            _vv_first=${VIGIL_CFG_VALUE[$i]}
            return 0
        fi
        i=$((i + 1))
    done
}

# Checks the authority of a URL (after the scheme) for a host and for
# credentials. Sets _vv_code/_vv_msg; never shows the URL.
_vigil_val_authority() {
    local auth=${1%%/*}
    if [ -z "$auth" ]; then
        _vv_code=E_URL
        _vv_msg="'url' has no host"
        return
    fi
    case $2:$auth in
        https:*@* | ssh:*:*@*)
            _vv_code=E_URL
            _vv_msg="'url' must not contain credentials; the value is not shown"
            ;;
    esac
}

# Checks one value. Sets _vv_code/_vv_msg (empty when valid) and, for
# backend_refs, _vv_warn to the first disabled backend named.
_vigil_val_check() {
    local type=$1 key=$2 value=$3 item lo hi
    _vv_code=''
    _vv_msg=''
    _vv_warn=''

    # Arguments may be empty: some tools take an empty argument (spec 6.4).
    if [ -z "$value" ] && [ "$type" != arg ]; then
        _vv_code=E_VALUE_EMPTY
        _vv_msg="'$key' has no value"
        return
    fi

    case $type in
        text | path | arg) ;;
        dur | dur0)
            if ! [[ $value =~ $_vigil_val_re_dur ]]; then
                _vv_code=E_DURATION
                _vv_msg="'$key' must be a duration such as 30s, 5m, 2h or 7d: $value"
            elif [ "$type" = dur ] && [[ $value =~ $_vigil_val_re_zero_dur ]]; then
                _vv_code=E_DURATION
                _vv_msg="'$key' must be greater than zero"
            fi
            ;;
        int | int1)
            if ! [[ $value =~ $_vigil_val_re_int ]]; then
                _vv_code=E_INTEGER
                _vv_msg="'$key' must be a whole number: $value"
            elif [ "$type" = int1 ] && [[ $value =~ $_vigil_val_re_zero ]]; then
                _vv_code=E_INTEGER
                _vv_msg="'$key' must be at least 1"
            fi
            ;;
        bool)
            case $value in
                true | false) ;;
                *) _vv_code=E_BOOLEAN; _vv_msg="'$key' must be true or false: $value" ;;
            esac
            ;;
        name)
            if ! [[ $value =~ $_vigil_val_re_name ]]; then
                _vv_code=E_NAME
                _vv_msg="'$key' may contain only letters, digits, '_', '.' and '-': $value"
            fi
            ;;
        metric)
            if ! [[ $value =~ $_vigil_val_re_metric ]]; then
                _vv_code=E_METRIC_NAME
                _vv_msg="'$key' must be dotted words of letters, digits and '_': $value"
            fi
            ;;
        times)
            _vigil_val_split "$value"
            for item in "${_vv_items[@]}"; do
                if ! [[ $item =~ $_vigil_val_re_time ]]; then
                    _vv_code=E_TIME
                    _vv_msg="'$key' times must be HH:MM, 24-hour: '$item'"
                    return
                fi
            done
            ;;
        days)
            _vigil_val_split "$value"
            for item in "${_vv_items[@]}"; do
                case $item in
                    [Mm][Oo][Nn] | [Tt][Uu][Ee] | [Ww][Ee][Dd] | [Tt][Hh][Uu] | \
                    [Ff][Rr][Ii] | [Ss][Aa][Tt] | [Ss][Uu][Nn]) ;;
                    *)
                        _vv_code=E_DAY
                        _vv_msg="'$key' days must be mon, tue, wed, thu, fri, sat or sun: '$item'"
                        return
                        ;;
                esac
            done
            ;;
        exit_codes)
            case $value in
                standard | nagios) return ;;
            esac
            _vigil_val_split "$value"
            for item in "${_vv_items[@]}"; do
                if [[ $item =~ $_vigil_val_re_code ]]; then
                    lo=$((10#${BASH_REMATCH[1]}))
                    hi=$lo
                    if [ -n "${BASH_REMATCH[3]}" ]; then
                        hi=$((10#${BASH_REMATCH[3]}))
                    fi
                    if [ "$lo" -le 255 ] && [ "$hi" -le 255 ] && [ "$lo" -le "$hi" ]; then
                        continue
                    fi
                fi
                _vv_code=E_EXIT_CODES
                _vv_msg="'$key' must be standard, nagios or a list of codes 0-255 such as 0,1 or 0-7: '$item'"
                return
            done
            ;;
        overlap)
            case $value in
                skip | queue_one) ;;
                *) _vv_code=E_ENUM; _vv_msg="'$key' must be skip or queue_one: $value" ;;
            esac
            ;;
        on_uncertain)
            case $value in
                wait | replace | manual) ;;
                *) _vv_code=E_ENUM; _vv_msg="'$key' must be wait, replace or manual: $value" ;;
            esac
            ;;
        when_full)
            case $value in
                drop_oldest | drop_newest) ;;
                *) _vv_code=E_ENUM; _vv_msg="'$key' must be drop_oldest or drop_newest: $value" ;;
            esac
            ;;
        backend_type)
            case $VIGIL_BACKEND_TYPES in
                *$'\n'"$value"$'\n'*) ;;
                *) _vv_code=E_BACKEND_TYPE; _vv_msg="unknown backend type: $value" ;;
            esac
            ;;
        runner_ref)
            case $_vv_runners in
                *$'\n'"$value"$'\n'*) ;;
                *) _vv_code=E_RUNNER_UNKNOWN; _vv_msg="no [runner.$value] section" ;;
            esac
            ;;
        backend_refs)
            _vigil_val_split "$value"
            for item in "${_vv_items[@]}"; do
                case $_vv_backends in
                    *$'\n'"$item"$'\n'*) ;;
                    *)
                        _vv_code=E_BACKEND_UNKNOWN
                        _vv_msg="no [backend.$item] section"
                        return
                        ;;
                esac
                if [ -z "$_vv_warn" ]; then
                    case $_vv_disabled in
                        *$'\n'"$item"$'\n'*) _vv_warn=$item ;;
                    esac
                fi
            done
            ;;
        tagpair)
            if ! [[ $value =~ $_vigil_val_re_tagpair ]]; then
                _vv_code=E_TAG_SYNTAX
                _vv_msg="'$key' must be key=value with a lowercase key and no spaces: $value"
                return
            fi
            case $VIGIL_RESERVED_TAGS in
                *$'\n'"${BASH_REMATCH[1]}"$'\n'*)
                    _vv_code=E_TAG_RESERVED
                    _vv_msg="tag '${BASH_REMATCH[1]}' is set by Vigil and cannot be declared"
                    ;;
            esac
            ;;
        envpair)
            if ! [[ $value =~ $_vigil_val_re_envpair ]]; then
                _vv_code=E_ENV_SYNTAX
                _vv_msg="'$key' must be NAME=value"
                return
            fi
            case ${BASH_REMATCH[2]} in
                env:*)
                    _vv_code=E_ENV_LITERAL
                    _vv_msg="'$key' values are literal; the job already inherits ${BASH_REMATCH[2]#env:} from the service environment"
                    ;;
            esac
            ;;
        envnames)
            _vigil_val_split "$value"
            for item in "${_vv_items[@]}"; do
                if ! [[ $item =~ $_vigil_val_re_envname ]]; then
                    _vv_code=E_ENV_NAME
                    _vv_msg="'$key' must list environment variable names: '$item'"
                    return
                fi
            done
            ;;
        source_type)
            case $value in
                local | git | https | sftp) ;;
                *) _vv_code=E_ENUM; _vv_msg="'$key' must be local, git, https or sftp: $value" ;;
            esac
            ;;
        port)
            if ! [[ $value =~ $_vigil_val_re_int ]] || [ $((10#$value)) -lt 1 ] || [ $((10#$value)) -gt 65535 ]; then
                _vv_code=E_INTEGER
                _vv_msg="'$key' must be a port number from 1 to 65535: $value"
            fi
            ;;
        url)
            # Checked against the source's type; the URL itself is never
            # shown, since a mistaken one may carry a password.
            case $_vv_stype in
                https)
                    case $value in
                        https://*) _vigil_val_authority "${value#https://}" https ;;
                        *) _vv_code=E_URL; _vv_msg="the 'url' of an https source must start with https://" ;;
                    esac
                    ;;
                git)
                    case $value in
                        https://*) _vigil_val_authority "${value#https://}" https ;;
                        ssh://*) _vigil_val_authority "${value#ssh://}" ssh ;;
                        *://*) _vv_code=E_URL; _vv_msg="a git 'url' must be https://, ssh:// or user@host:path" ;;
                        *)
                            if ! [[ $value =~ $_vigil_val_re_scp ]]; then
                                _vv_code=E_URL
                                _vv_msg="a git 'url' must be https://, ssh:// or user@host:path"
                            fi
                            ;;
                    esac
                    ;;
            esac
            ;;
        srcpath)
            case $value in
                /* | *\\* | [A-Za-z]:*) _vv_code=E_SOURCE_PATH ;;
            esac
            case /$value/ in
                */../*) _vv_code=E_SOURCE_PATH ;;
            esac
            if [ -n "$_vv_code" ]; then
                _vv_msg="'$key' must be a relative path inside the source, with / separators and no .. segments: $value"
            fi
            ;;
        source_ref)
            _vigil_val_source_type "$value"
            if [ "$_vv_found" -eq 0 ]; then
                _vv_code=E_SOURCE_UNKNOWN
                _vv_msg="no [source.$value] section"
            fi
            ;;
        sha256)
            if ! [[ $value =~ $_vigil_val_re_sha256 ]]; then
                _vv_code=E_SHA256
                _vv_msg="'$key' must be 64 hexadecimal digits"
            fi
            ;;
        credential)
            case $value in
                env:*)
                    if ! [[ $value =~ $_vigil_val_re_cred ]]; then
                        _vv_code=E_ENV_NAME
                        _vv_msg="'$key' must be env:NAME with a valid variable name"
                    fi
                    ;;
                *)
                    # Never echo the value: it may be a pasted secret.
                    _vv_code=E_SECRET_RAW
                    _vv_msg="'$key' must be an env:NAME reference; the value is not shown"
                    ;;
            esac
            ;;
    esac
}

# vigil_config_validate
# Validates the last vigil_config_parse. Returns 0 when there is no ERROR
# record (INVALID jobs and warnings do not reject the configuration).
vigil_config_validate() {
    VIGIL_VAL_KIND=()
    VIGIL_VAL_JOB=()
    VIGIL_VAL_LINE=()
    VIGIL_VAL_CODE=()
    VIGIL_VAL_MSG=()

    local LC_ALL=C
    local nl=$'\n'
    local count=${#VIGIL_CFG_KEY[@]}
    local s si e name sline kind sub key value line seen req pointer=''
    local has_file has_every has_at has_days has_command has_type has_sha256
    local has_config_file
    local tag_keys env_names

    # Names that references may point at, and each source's type (empty
    # when not valid).
    _vv_runners=$nl
    _vv_backends=$nl
    _vv_disabled=$nl
    _vv_src_names=()
    _vv_src_types=()
    s=0
    while [ "$s" -lt "${#VIGIL_CFG_SEC_NAME[@]}" ]; do
        name=${VIGIL_CFG_SEC_NAME[$s]}
        case $name in
            runner.*) _vv_runners="$_vv_runners${name#runner.}$nl" ;;
            backend.*) _vv_backends="$_vv_backends${name#backend.}$nl" ;;
            vigil)
                # A config_source makes this file a pointer to the real one.
                _vigil_val_first "$s" config_source
                pointer=$_vv_first
                ;;
            source.*)
                _vigil_val_first "$s" type
                case $_vv_first in
                    local | git | https | sftp) ;;
                    *) _vv_first='' ;;
                esac
                _vv_src_names[${#_vv_src_names[@]}]=${name#source.}
                _vv_src_types[${#_vv_src_types[@]}]=$_vv_first
                ;;
        esac
        s=$((s + 1))
    done
    e=0
    while [ "$e" -lt "$count" ]; do
        case ${VIGIL_CFG_SECTION[$e]} in
            backend.*)
                if [ "${VIGIL_CFG_KEY[$e]}" = enabled ] && [ "${VIGIL_CFG_VALUE[$e]}" = false ]; then
                    _vv_disabled="$_vv_disabled${VIGIL_CFG_SECTION[$e]#backend.}$nl"
                fi
                ;;
        esac
        e=$((e + 1))
    done

    e=0
    s=0
    while [ "$s" -lt "${#VIGIL_CFG_SEC_NAME[@]}" ]; do
        name=${VIGIL_CFG_SEC_NAME[$s]}
        sline=${VIGIL_CFG_SEC_LINE[$s]}
        si=$s
        s=$((s + 1))
        sub=''
        _vv_job=''
        case $name in
            vigil | scheduler | log | tags | spool | defaults | runners) kind=$name ;;
            backend.* | runner.* | job.* | source.*) kind=${name%%.*}; sub=${name#*.} ;;
            *) kind='' ;;
        esac
        if [ "$kind" = job ]; then
            _vv_job=$sub
        fi

        req=ok
        if [ -z "$kind" ]; then
            _vigil_val_report "$sline" E_SECTION_UNKNOWN "unknown section [$name]"
            req=skip
        elif [ -n "$pointer" ] && [ "$kind" != vigil ] && [ "$name" != "source.$pointer" ]; then
            # A pointer file holds only where the configuration is (6.8).
            _vigil_val_report "$sline" E_POINTER_ONLY "[$name] belongs in the configuration fetched from [source.$pointer], not in this file"
            req=skip
        fi
        if [ "$req" = skip ]; then
            # The section is rejected as a whole; its keys are not checked.
            while [ "$e" -lt "$count" ] && [ "${VIGIL_CFG_SECTION[$e]}" = "$name" ]; do
                e=$((e + 1))
            done
            continue
        fi

        # What the section's keys are checked against: a job's source and
        # its type, or a source's own type.
        _vv_jsource=''
        _vv_jtype=''
        _vv_stype=''
        case $kind in
            job)
                _vigil_val_first "$si" source
                _vv_jsource=$_vv_first
                if [ -n "$_vv_jsource" ]; then
                    _vigil_val_source_type "$_vv_jsource"
                    _vv_jtype=$_vv_srctype
                fi
                ;;
            source)
                _vigil_val_first "$si" type
                case $_vv_first in
                    local | git | https | sftp) _vv_stype=$_vv_first ;;
                esac
                ;;
        esac

        seen=$nl
        tag_keys=$nl
        env_names=$nl
        has_file=0 has_every=0 has_at=0 has_days=0 has_command=0 has_type=0 has_sha256=0
        has_config_file=0

        while [ "$e" -lt "$count" ] && [ "${VIGIL_CFG_SECTION[$e]}" = "$name" ]; do
            key=${VIGIL_CFG_KEY[$e]}
            value=${VIGIL_CFG_VALUE[$e]}
            line=${VIGIL_CFG_LINE[$e]}
            e=$((e + 1))

            case $key in
                file) has_file=1 ;;
                run_every) has_every=1 ;;
                run_at) has_at=1 ;;
                run_on_days) has_days=1 ;;
                command) has_command=1 ;;
                type) has_type=1 ;;
                sha256) has_sha256=1 ;;
                config_file) has_config_file=1 ;;
            esac

            case $kind in
                tags)
                    if ! [[ $key =~ $_vigil_val_re_tagkey ]]; then
                        _vigil_val_report "$line" E_TAG_SYNTAX "invalid tag key: '$key'"
                        continue
                    fi
                    case $VIGIL_RESERVED_TAGS in
                        *$nl"$key"$nl*)
                            _vigil_val_report "$line" E_TAG_RESERVED "tag '$key' is set by Vigil and cannot be declared"
                            continue
                            ;;
                    esac
                    _vv_type=tagvalue
                    _vv_list=0
                    ;;
                runners)
                    if ! [[ $key =~ $_vigil_val_re_ext ]]; then
                        _vigil_val_report "$line" E_EXTENSION "[runners] keys must be file extensions such as .sql: '$key'"
                        continue
                    fi
                    _vv_type=runner_ref
                    _vv_list=0
                    ;;
                *)
                    _vigil_val_keytype "$kind" "$key"
                    ;;
            esac

            if [ -z "$_vv_type" ]; then
                _vigil_val_report "$line" E_KEY_UNKNOWN "unknown key '$key' in [$name]"
                continue
            fi
            if [ -n "$pointer" ] && [ "$kind" = vigil ]; then
                case $key in
                    config_source | config_file | state_dir) ;;
                    *)
                        _vigil_val_report "$line" E_POINTER_ONLY "'$key' belongs in the configuration fetched from [source.$pointer], not in this file"
                        continue
                        ;;
                esac
            fi
            if [ -n "$_vv_stype" ] && ! _vigil_val_source_key "$_vv_stype" "$key"; then
                _vigil_val_report "$line" E_KEY_UNKNOWN "'$key' does not apply to a $_vv_stype source"
                continue
            fi
            if [ "$_vv_type" = job_only ]; then
                _vigil_val_report "$line" E_KEY_NOT_DEFAULTABLE "'$key' must be set on each job, not in [defaults]"
                continue
            fi
            if [ "$_vv_list" -eq 0 ]; then
                case $seen in
                    *$nl"$key"$nl*)
                        _vigil_val_report "$line" E_KEY_DUPLICATE "'$key' is set more than once in [$name]"
                        continue
                        ;;
                esac
                seen="$seen$key$nl"
            fi

            if [ "$_vv_type" = tagvalue ]; then
                if [ -z "$value" ]; then
                    _vv_code=E_VALUE_EMPTY
                    _vv_msg="'$key' has no value"
                elif ! [[ $value =~ $_vigil_val_re_tagvalue ]]; then
                    _vv_code=E_TAG_SYNTAX
                    _vv_msg="tag values cannot contain spaces: '$key'"
                else
                    _vv_code=''
                fi
            else
                _vigil_val_check "$_vv_type" "$key" "$value"
            fi
            if [ -n "$_vv_code" ]; then
                _vigil_val_report "$line" "$_vv_code" "$_vv_msg"
                continue
            fi

            case $_vv_type in
                tagpair)
                    case $tag_keys in
                        *$nl"${value%%=*}"$nl*)
                            _vigil_val_report "$line" E_TAG_DUPLICATE "tag '${value%%=*}' is set more than once in [$name]"
                            continue
                            ;;
                    esac
                    tag_keys="$tag_keys${value%%=*}$nl"
                    ;;
                envpair)
                    case $env_names in
                        *$nl"${value%%=*}"$nl*)
                            _vigil_val_report "$line" E_ENV_DUPLICATE "env '${value%%=*}' is set more than once in [$name]"
                            continue
                            ;;
                    esac
                    env_names="$env_names${value%%=*}$nl"
                    ;;
                backend_refs)
                    if [ -n "$_vv_warn" ]; then
                        _vigil_val_add WARN '' "$line" W_BACKEND_DISABLED "backend '$_vv_warn' is disabled"
                    fi
                    ;;
            esac
        done

        case $kind in
            job)
                case $sub in
                    vigil_*)
                        _vigil_val_report "$sline" E_JOB_ID_RESERVED "job ids starting with vigil_ are reserved"
                        ;;
                esac
                if [ "$has_file" -eq 0 ]; then
                    _vigil_val_report "$sline" E_KEY_REQUIRED "[$name] needs 'file'"
                fi
                if [ "$has_every" -eq 1 ] && [ "$has_at" -eq 1 ]; then
                    _vigil_val_report "$sline" E_SCHEDULE_BOTH "use run_every or run_at, not both; list the times in run_at"
                elif [ "$has_every" -eq 0 ] && [ "$has_at" -eq 0 ]; then
                    if [ "$has_days" -eq 1 ]; then
                        _vigil_val_report "$sline" E_SCHEDULE_DAYS_ONLY "run_on_days needs run_every or run_at"
                    else
                        _vigil_val_report "$sline" E_SCHEDULE_NONE "[$name] needs run_every or run_at"
                    fi
                fi
                # Scripts from versionless sources are pinned by digest (6.9).
                if [ "$has_sha256" -eq 0 ]; then
                    case $_vv_jtype in
                        https | sftp)
                            _vigil_val_report "$sline" E_SHA256_REQUIRED "[$name] needs 'sha256': scripts from $_vv_jtype sources are pinned by digest"
                            ;;
                        local)
                            _vigil_val_add WARN '' "$sline" W_SCRIPT_UNPINNED "[$name] has no 'sha256'; its script follows changes in the source, so hosts may briefly differ"
                            ;;
                    esac
                fi
                ;;
            source)
                req=''
                if [ "$has_type" -eq 0 ]; then
                    req=type
                else
                    case $_vv_stype in
                        local) req='path' ;;
                        git) req='url ref' ;;
                        https) req='url' ;;
                        sftp) req='host path' ;;
                    esac
                    for key in $req; do
                        case $seen in
                            *$nl"$key"$nl*) ;;
                            *) req=$key; break ;;
                        esac
                        req=''
                    done
                fi
                if [ -n "$req" ]; then
                    _vigil_val_report "$sline" E_KEY_REQUIRED "[$name] needs '$req'"
                fi
                ;;
            vigil)
                # config_source and config_file go together.
                if [ -n "$pointer" ] && [ "$has_config_file" -eq 0 ]; then
                    _vigil_val_report "$sline" E_KEY_REQUIRED "[$name] needs 'config_file' with 'config_source'"
                elif [ -z "$pointer" ] && [ "$has_config_file" -eq 1 ]; then
                    _vigil_val_report "$sline" E_KEY_REQUIRED "[$name] needs 'config_source' with 'config_file'"
                fi
                ;;
            runner)
                if [ "$has_command" -eq 0 ]; then
                    _vigil_val_report "$sline" E_KEY_REQUIRED "[$name] needs 'command'"
                fi
                ;;
            backend)
                if [ "$has_type" -eq 0 ]; then
                    case $VIGIL_BACKEND_TYPES in
                        *$nl"$sub"$nl*) ;;
                        *) _vigil_val_report "$sline" E_BACKEND_TYPE "[$name] needs 'type': '$sub' is not a backend type" ;;
                    esac
                fi
                ;;
        esac
    done

    _vigil_val_collisions

    local i=0
    while [ "$i" -lt "${#VIGIL_VAL_KIND[@]}" ]; do
        if [ "${VIGIL_VAL_KIND[$i]}" = ERROR ]; then
            return 1
        fi
        i=$((i + 1))
    done
    return 0
}

# Warns when two jobs' different base metric names become the same name in
# a backend that only allows underscores (spec 14.1): "a.b_c" and "a_b.c"
# are both a_b_c there. Only jobs sending to the same such backend clash.
_vigil_val_collisions() {
    local nl=$'\n' s name type under list item i j
    local us=$nl
    local -a jname jbase junder jline jset
    jname=() jbase=() junder=() jline=() jset=()

    # Enabled backends whose format allows only underscores in names.
    s=0
    while [ "$s" -lt "${#VIGIL_CFG_SEC_NAME[@]}" ]; do
        name=${VIGIL_CFG_SEC_NAME[$s]}
        case $name in
            backend.*)
                _vigil_val_first "$s" type
                type=${_vv_first:-${name#backend.}}
                case $_vv_disabled in
                    *$nl"${name#backend.}"$nl*) ;;
                    *)
                        case $type in
                            file | prometheus | victoriametrics) us="$us${name#backend.}$nl" ;;
                        esac
                        ;;
                esac
                ;;
        esac
        s=$((s + 1))
    done
    [ "$us" = "$nl" ] && return 0

    # The default backend list, as for a job without "backends".
    local deflist=''
    vigil_config_section defaults
    if [ "$VIGIL_CFG_SEC" -ge 0 ]; then
        _vigil_val_first "$VIGIL_CFG_SEC" backends
        deflist=$_vv_first
    fi

    s=0
    while [ "$s" -lt "${#VIGIL_CFG_SEC_NAME[@]}" ]; do
        name=${VIGIL_CFG_SEC_NAME[$s]}
        case $name in
            job.*) ;;
            *) s=$((s + 1)); continue ;;
        esac
        _vigil_val_first "$s" metric_name
        item=${_vv_first:-${name#job.}}
        if ! [[ $item =~ $_vigil_val_re_metric ]]; then
            s=$((s + 1))
            continue
        fi
        _vigil_val_first "$s" backends
        list=${_vv_first:-$deflist}
        # The underscore-only backends this job sends to.
        local set=$nl
        if [ -n "$list" ]; then
            _vigil_val_split "$list"
            for type in "${_vv_items[@]}"; do
                case $us in *$nl"$type"$nl*) set="$set$type$nl" ;; esac
            done
        else
            set=$us
        fi
        if [ "$set" != "$nl" ]; then
            i=${#jname[@]}
            jname[$i]=${name#job.}
            jbase[$i]=$item
            junder[$i]=${item//./_}
            jline[$i]=${VIGIL_CFG_SEC_LINE[$s]}
            jset[$i]=$set
        fi
        s=$((s + 1))
    done

    j=1
    while [ "$j" -lt "${#jname[@]}" ]; do
        i=0
        while [ "$i" -lt "$j" ]; do
            if [ "${junder[$i]}" = "${junder[$j]}" ] && [ "${jbase[$i]}" != "${jbase[$j]}" ]; then
                under=''
                for type in ${jset[$j]}; do
                    case ${jset[$i]} in *$nl"$type"$nl*) under=$type; break ;; esac
                done
                if [ -n "$under" ]; then
                    _vigil_val_add WARN '' "${jline[$j]}" W_METRIC_COLLISION "metric '${jbase[$j]}' becomes '${junder[$j]}' in backend '$under', the same as '${jbase[$i]}' of [job.${jname[$i]}]"
                    break
                fi
            fi
            i=$((i + 1))
        done
        j=$((j + 1))
    done
}

# vigil_config_validate_dump
# Prints the last parse's errors and validation records in the conformance
# format, one per line:
#   ERROR TAB <line> TAB <code>                 parser errors, then validation
#   INVALID TAB <job> TAB <line> TAB <code>
#   WARN TAB <line> TAB <code>
vigil_config_validate_dump() {
    local i=0 e
    while [ "$i" -lt "${#VIGIL_CFG_ERRORS[@]}" ]; do
        e=${VIGIL_CFG_ERRORS[$i]}
        printf 'ERROR\t%s\t%s\n' "${e%%	*}" "$(printf '%s' "$e" | cut -f2)"
        i=$((i + 1))
    done
    i=0
    while [ "$i" -lt "${#VIGIL_VAL_KIND[@]}" ]; do
        if [ "${VIGIL_VAL_KIND[$i]}" = INVALID ]; then
            printf 'INVALID\t%s\t%s\t%s\n' "${VIGIL_VAL_JOB[$i]}" "${VIGIL_VAL_LINE[$i]}" "${VIGIL_VAL_CODE[$i]}"
        else
            printf '%s\t%s\t%s\n' "${VIGIL_VAL_KIND[$i]}" "${VIGIL_VAL_LINE[$i]}" "${VIGIL_VAL_CODE[$i]}"
        fi
        i=$((i + 1))
    done
}
