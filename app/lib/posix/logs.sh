# shellcheck shell=bash
#
# Vigil log forwarder - bash 3.2 compatible.
#
# The body of the vigil_logs worker (SPECIFICATION.md 13.4): sends what is
# new in Vigil's own logs to the [log_destination.*] in OTLP/HTTP JSON, one
# file and one request at a time, and moves each file's checkpoint only past
# what the destination accepted. Local logs are never changed.
#
#   vigil_logs
#     Called by the worker after its claim, with the configuration parsed
#     and _vw_root, _vw_statedir, _vw_logdir, _vw_spooldir, _vw_host and
#     _vw_os set. Returns 0, or 1 with _vw_reason set when delivery failed.
#   vigil_logs_enabled
#     Whether the parsed configuration forwards logs.
#   vigil_logs_total <log dir>
#     The size of every forwarded log file, in _vl_total.
#   vigil_logs_settings
#     Reads what a record needs from the parsed configuration, for
#     vigil_logs_record: _vl_include and _vl_output.
#   vigil_logs_record <file> <line>
#     Pure: the OTLP log record of one line of log file <file> (relative to
#     the log directory), in _vl_rec, empty when the line is not forwarded.
#     Must produce exactly what Logs.ps1 does - tests/conformance/logs holds
#     the shared cases.
#   vigil_logs_retention <log dir> <epoch>
#     Deletes the log files older than their retention (13.1).
#   vigil_logs_output_for <job id>
#     Sets _vl_output: whether the job's stdout and stderr may be forwarded.
#
# Requires config.sh, worker.sh, secrets.sh, stores.sh and fetch.sh.

VIGIL_LOGS_LINE_MAX=65536
# The longest one forwarder runs: it stops starting requests after this, so
# it stays within its fixed 5 minutes (13.4.3).
VIGIL_LOGS_RUN_SECS=240

_vigil_logs_iso='^([0-9][0-9][0-9][0-9])-([0-9][0-9])-([0-9][0-9])T([0-9][0-9]):([0-9][0-9]):([0-9][0-9])Z$'
_vigil_logs_num='^[0-9]+$'
_vigil_logs_dated='^([0-9][0-9][0-9][0-9])-([0-9][0-9])-([0-9][0-9])([.][0-9]+)?[.]log$'
_vigil_logs_rejected='"rejectedLogRecords"[[:space:]]*:[[:space:]]*"?([0-9]+)'

vigil_logs_enabled() {
    vigil_config_section log_forward
    [ "$VIGIL_CFG_SEC" -ge 0 ] || return 1
    _vigil_wk_get log_forward enabled true
    [ "$_vw_value" != false ]
}

# Every forwarded log file: _vl_list, one "<size> <file>" per line, oldest
# first (by file name, so a day's files sort together). The status file and
# the forwarder's own log are never forwarded (13.4.2).
_vigil_logs_list() {
    local nl=$'\n' size name base out=''
    while read -r size name; do
        case $name in
            '' | total | supervisor/jobs.log | jobs/vigil_logs/*) continue ;;
        esac
        # A day's first file sorts before its numbered ones.
        base=${name##*/}
        case $base in ????-??-??.log) base="${base%.log}.0.log" ;; esac
        out="$out$base"$'\t'"$name"$'\t'"$size$nl"
    done <<EOF
$(cd "$1" 2>/dev/null && wc -c -- supervisor/*.log jobs/*/*.log 2>/dev/null)
EOF
    _vl_list=$(printf '%s' "$out" | LC_ALL=C sort | cut -f2,3)
}

vigil_logs_total() {
    local name size
    _vl_total=0
    _vigil_logs_list "$1"
    while IFS=$'\t' read -r name size; do
        [ -n "$name" ] && _vl_total=$((_vl_total + size))
    done <<EOF
$_vl_list
EOF
}

# Whether job $1's stdout and stderr may be forwarded: never for a job the
# configuration no longer names, since its forward_output is not known.
vigil_logs_output_for() {
    _vl_output=0
    vigil_config_section "job.$1"
    [ "$VIGIL_CFG_SEC" -ge 0 ] || return 0
    _vigil_wk_get defaults forward_output true
    _vigil_wk_get "job.$1" forward_output "$_vw_value"
    [ "$_vw_value" = false ] || _vl_output=1
}

vigil_logs_settings() {
    _vigil_wk_get log_forward include 'supervisor, run'
    _vl_include=" ${_vw_value//,/ } "
    _vl_output=1
}

# $1 as the inside of a JSON string, into _vl_text. Control characters and
# invalid UTF-8 are escaped, never sent raw (13.4.5). Needs LC_ALL=C.
_vigil_logs_text() {
    local s=$1 i=0 n=${#1} c b out='' more low high j
    case $s in
        *[![:print:]]* | *\\* | *\"*) ;;
        *)
            _vl_text=$s
            return 0
            ;;
    esac
    while [ "$i" -lt "$n" ]; do
        c=${s:i:1}
        printf -v b '%d' "'$c"
        b=$((b & 255))
        i=$((i + 1))
        if [ "$b" -lt 128 ]; then
            case $c in
                \") out="$out\\\"" ;;
                \\) out="$out\\\\" ;;
                *)
                    if [ "$b" -lt 32 ] || [ "$b" -eq 127 ]; then
                        printf -v c '\\u%04x' "$b"
                    fi
                    out=$out$c
                    ;;
            esac
            continue
        fi
        more=0 low=128 high=191
        if [ "$b" -ge 194 ] && [ "$b" -le 223 ]; then more=1
        elif [ "$b" -eq 224 ]; then more=2 low=160
        elif [ "$b" -eq 237 ]; then more=2 high=159
        elif [ "$b" -ge 225 ] && [ "$b" -le 239 ]; then more=2
        elif [ "$b" -eq 240 ]; then more=3 low=144
        elif [ "$b" -eq 244 ]; then more=3 high=143
        elif [ "$b" -ge 241 ] && [ "$b" -le 243 ]; then more=3
        fi
        j=0
        while [ "$j" -lt "$more" ]; do
            if [ $((i + j)) -ge "$n" ]; then more=0; break; fi
            printf -v b '%d' "'${s:i+j:1}"
            b=$((b & 255))
            if [ "$b" -lt "$low" ] || [ "$b" -gt "$high" ]; then more=0; break; fi
            low=128 high=191
            j=$((j + 1))
        done
        if [ "$more" -eq 0 ]; then
            out="$out\\ufffd"
        else
            out=$out$c${s:i:more}
            i=$((i + more))
        fi
    done
    _vl_text=$out
}

# One attribute, into _vl_attr.
_vigil_logs_attr() {
    _vigil_logs_text "$2"
    _vl_attr="{\"key\":\"$1\",\"value\":{\"stringValue\":\"$_vl_text\"}}"
}

# Days since 1970 of year $1, month $2, day $3, into _vl_days.
_vigil_logs_days() {
    local y=$((10#$1)) m=$((10#$2)) d=$((10#$3)) era yoe doy doe
    [ "$m" -le 2 ] && y=$((y - 1))
    era=$((y / 400))
    yoe=$((y - era * 400))
    doy=$(((153 * ((m + 9) % 12) + 2) / 5 + d - 1))
    doe=$((yoe * 365 + yoe / 4 - yoe / 100 + doy))
    _vl_days=$((era * 146097 + doe - 719468))
}

# Seconds since 1970 of the time in BASH_REMATCH, into _vl_epoch.
_vigil_logs_epoch() {
    local h=${BASH_REMATCH[4]} m=${BASH_REMATCH[5]} s=${BASH_REMATCH[6]}
    _vigil_logs_days "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    _vl_epoch=$((_vl_days * 86400 + 10#$h * 3600 + 10#$m * 60 + 10#$s))
}

# How many days job $1's log is kept (6.6), or the supervisor's with no
# job, into _vl_keep.
_vigil_logs_keep() {
    _vigil_wk_get log retain_days 7
    if [ -n "$1" ]; then
        _vigil_wk_get defaults log_retain_days "$_vw_value"
        _vigil_wk_get "job.$1" log_retain_days "$_vw_value"
    fi
    _vl_keep=$_vw_value
}

# Deletes dated log files older than their retention (13.1), whole, and
# never for the forwarder's sake (13.4.4). The status file has no date.
# $1 is the log directory, $2 the time. The number deleted is in _vl_removed.
vigil_logs_retention() {
    local today=$(($2 / 86400)) f job
    _vl_removed=0
    for f in "$1"/supervisor/*.log "$1"/jobs/*/*.log; do
        [ -f "$f" ] || continue
        job=''
        case $f in
            "$1"/jobs/*)
                job=${f#"$1"/jobs/}
                job=${job%%/*}
                ;;
        esac
        _vigil_logs_keep "$job"
        [[ ${f##*/} =~ $_vigil_logs_dated ]] || continue
        _vigil_logs_days "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
        if [ $((today - _vl_days)) -gt "$_vl_keep" ] && rm -f "$f"; then
            _vl_removed=$((_vl_removed + 1))
        fi
    done
}

vigil_logs_record() {
    local file=$1 line=${2%$'\r'} when rest r2 level='' category msg job='' rid='' stream sev='' attrs cut=0 outcome
    _vl_rec=''
    when=${line%% *}
    rest=''
    case $line in *' '*) rest=${line#* } ;; esac
    msg=$line
    case $file in
        supervisor/*)
            category=supervisor
            r2=''
            case $rest in *' '*) r2=${rest#* } ;; esac
            case $rest in
                'INFO supervisor '* | 'WARN supervisor '* | 'ERROR supervisor '*)
                    level=${rest%% *}
                    msg=${r2#supervisor }
                    ;;
                *) when='' ;;
            esac
            case $level in
                INFO) sev=info ;;
                WARN) sev=warn ;;
                ERROR) sev=error ;;
            esac
            ;;
        *)
            job=${file#jobs/}
            job=${job%%/*}
            category=run
            r2=''
            case $rest in *' '*) r2=${rest#* } ;; esac
            stream=${r2%% *}
            case $stream in
                run | out | err)
                    rid=${rest%% *}
                    msg=''
                    case $r2 in *' '*) msg=${r2#* } ;; esac
                    case $stream in
                        out) category=stdout ;;
                        err) category=stderr ;;
                        run)
                            sev=info
                            case $msg in
                                'end '*)
                                    outcome=${msg#end }
                                    outcome=${outcome%% *}
                                    case $outcome in
                                        warning) sev=warn ;;
                                        failed | unknown | timed_out | crashed) sev=error ;;
                                    esac
                                    ;;
                            esac
                            ;;
                    esac
                    ;;
                *)
                    # Not a line in the job log format: kept, as it stands.
                    when=''
                    sev=info
                    ;;
            esac
            ;;
    esac
    case $_vl_include in *" $category "*) ;; *) return 0 ;; esac
    case $category in stdout | stderr) [ "$_vl_output" = 1 ] || return 0 ;; esac
    if [ "${#msg}" -gt "$VIGIL_LOGS_LINE_MAX" ]; then
        msg=${msg:0:VIGIL_LOGS_LINE_MAX}
        cut=1
    fi

    _vl_epoch=0
    if [[ $when =~ $_vigil_logs_iso ]]; then
        _vigil_logs_epoch
        _vl_rec="{\"timeUnixNano\":\"${_vl_epoch}000000000\","
    else
        _vl_rec='{"timeUnixNano":"0",'
    fi
    case $sev in
        info) _vl_rec="$_vl_rec\"severityNumber\":9,\"severityText\":\"INFO\"," ;;
        warn) _vl_rec="$_vl_rec\"severityNumber\":13,\"severityText\":\"WARN\"," ;;
        error) _vl_rec="$_vl_rec\"severityNumber\":17,\"severityText\":\"ERROR\"," ;;
    esac
    _vigil_logs_text "$msg"
    _vl_rec="$_vl_rec\"body\":{\"stringValue\":\"$_vl_text\"},\"attributes\":["
    if [ "$category" = supervisor ]; then
        _vigil_logs_attr component supervisor
    else
        _vigil_logs_attr component job
    fi
    attrs=$_vl_attr
    _vigil_logs_attr category "$category"
    attrs="$attrs,$_vl_attr"
    if [ -n "$job" ]; then
        _vigil_logs_attr job "$job"
        attrs="$attrs,$_vl_attr"
    fi
    if [ -n "$rid" ]; then
        _vigil_logs_attr run_id "$rid"
        attrs="$attrs,$_vl_attr"
    fi
    _vigil_logs_attr source_file "$file"
    attrs="$attrs,$_vl_attr"
    if [ "$cut" -eq 1 ]; then
        _vigil_logs_attr truncated true
        attrs="$attrs,$_vl_attr"
    fi
    _vl_rec="$_vl_rec$attrs]}"
}

# The resource every record of a request shares (13.4.2), into _vl_resource.
_vigil_logs_resource() {
    local attrs tag
    _vigil_logs_attr service.name vigil
    attrs=$_vl_attr
    for tag in $_vf_tags; do
        _vigil_logs_attr "${tag%%=*}" "${tag#*=}"
        attrs="$attrs,$_vl_attr"
    done
    _vigil_logs_attr config.revision "$_vl_revision"
    _vl_resource="{\"attributes\":[$attrs,$_vl_attr]}"
}

# Counts a gap of $2 bytes with reason $1, once in the run's totals.
_vigil_logs_gap() {
    _vl_events[${#_vl_events[@]}]="$_vl_now vigil.logs.gaps 1 count $_vf_tags reason=$1"
    _vl_events[${#_vl_events[@]}]="$_vl_now vigil.logs.gap_bytes $2 count $_vf_tags reason=$1"
    _vigil_wk_log "$_vw_run run gap in ${3:-the logs}: $2 bytes ($1)"
}

# A failed request: reason $1, text $2. The run stops and backs off.
_vigil_logs_failed() {
    _vl_failed=$2
    _vl_events[${#_vl_events[@]}]="$_vl_now vigil.logs.failures 1 count $_vf_tags reason=$1"
}

# The checkpoint of a log file: its path in _vl_ck.
_vigil_logs_ckpath() {
    local e=$1
    e=${e//%/%25}
    e=${e//\//%2F}
    _vl_ck="$_vl_dir/logs%2F$e.checkpoint"
}

# Reads checkpoint _vl_ck: _ck_state (none, ok or bad), _ck_offset,
# _ck_crc, _ck_n and _ck_size.
_vigil_logs_ckread() {
    local line
    _ck_state=none _ck_offset=0 _ck_crc='' _ck_n=0 _ck_size=0 _ck_file=''
    [ -e "$_vl_ck" ] || return 0
    _ck_state=bad
    _ck_offset=''
    [ -r "$_vl_ck" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case $line in
            'file '*) _ck_file=${line#*= } ;;
            'fingerprint '*)
                _ck_crc=${line#*= }
                _ck_n=${_ck_crc##* }
                _ck_crc=${_ck_crc%% *}
                ;;
            'offset '*) _ck_offset=${line#*= } ;;
            'size '*) _ck_size=${line#*= } ;;
        esac
    done < "$_vl_ck"
    if [[ $_ck_offset =~ $_vigil_logs_num ]] && [[ $_ck_n =~ $_vigil_logs_num ]] && [[ $_ck_crc =~ $_vigil_logs_num ]] &&
        [[ $_ck_size =~ $_vigil_logs_num ]]; then
        _ck_state=ok
    else
        _ck_offset=0
        _ck_size=0
    fi
}

# The fingerprint of log file $1: the cksum of its first $2 bytes, as
# _fp_crc and _fp_n (the bytes fingerprinted).
_vigil_logs_fingerprint() {
    set -- $(head -c "$2" "$1" 2>/dev/null | cksum)
    _fp_crc=${1-} _fp_n=${2-0}
}

# Writes checkpoint _vl_ck for file $1 at offset $2, of size $3.
_vigil_logs_ckwrite() {
    {
        printf '[checkpoint]\n'
        printf 'file        = logs/%s\n' "$1"
        printf 'fingerprint = %s %s\n' "$_fp_crc" "$_fp_n"
        printf 'offset      = %s\n' "$2"
        printf 'size        = %s\n' "$3"
    } > "$_vl_ck.tmp.$$" && mv -f "$_vl_ck.tmp.$$" "$_vl_ck"
}

# Sends the _vl_n records in _vl_batch. Sets _vl_accepted, the leading
# records accepted; returns 1 after _vigil_logs_failed unless all were.
_vigil_logs_send() {
    local rejected=0 reply
    _vl_accepted=0
    _vh_headers=('Content-Type: application/json')
    [ -z "$_vl_header" ] || _vh_headers[1]=$_vl_header
    _vh_body="{\"resourceLogs\":[{\"resource\":$_vl_resource,\"scopeLogs\":[{\"scope\":{\"name\":\"vigil\"},\"logRecords\":[$_vl_batch]}]}]}"
    if ! _vigil_http_send "$_vl_secs" POST "$_vl_url" '' "$_vl_meta"; then
        _vh_headers=()
        _vh_body=''
        case $_vh_fail in
            timeout) _vigil_logs_failed timeout "no answer from $_vl_host within ${_vl_secs}s" ;;
            resolve) _vigil_logs_failed unreachable "cannot resolve $_vl_host" ;;
            connect) _vigil_logs_failed unreachable "cannot connect to $_vl_host" ;;
            nocurl) _vigil_logs_failed unreachable 'curl not found' ;;
            untrusted) _vigil_logs_failed unreachable "the certificate of $_vl_host is not trusted" ;;
            *) _vigil_logs_failed unreachable "the request to $_vl_host failed" ;;
        esac
        return 1
    fi
    _vh_headers=()
    _vh_body=''
    case $_vh_status in
        2??) ;;
        401 | 403)
            _vigil_logs_failed auth "permission denied (HTTP $_vh_status)"
            return 1
            ;;
        408 | 429 | 5??)
            _vigil_logs_failed unreachable "HTTP $_vh_status from $_vl_host"
            return 1
            ;;
        4??)
            _vigil_logs_failed rejected "HTTP $_vh_status from $_vl_host"
            return 1
            ;;
        *)
            _vigil_logs_failed invalid_response "HTTP $_vh_status from $_vl_host"
            return 1
            ;;
    esac
    # An empty answer or a JSON object; anything else is a failure, never a
    # success (13.4.5).
    reply=$(printf '%s' "$_vh_resp" | tr -d ' \t\r\n')
    case $reply in
        '' | \{*\}) ;;
        *)
            _vigil_logs_failed invalid_response "an answer from $_vl_host that is not OTLP"
            return 1
            ;;
    esac
    if [[ $_vh_resp =~ $_vigil_logs_rejected ]]; then
        rejected=${BASH_REMATCH[1]}
        [ "${#rejected}" -gt 9 ] && rejected=$_vl_n
        rejected=$((10#$rejected))
    fi
    [ "$rejected" -gt "$_vl_n" ] && rejected=$_vl_n
    _vl_accepted=$((_vl_n - rejected))
    if [ "$rejected" -gt 0 ]; then
        _vigil_logs_failed rejected "$_vl_host rejected $rejected of $_vl_n records"
        return 1
    fi
    return 0
}

# Forwards what is new in log file $1 (size $2). Returns 1 to end the run.
_vigil_logs_file() {
    local file=$1 size=$2 path="$_vw_logdir/$1" offset pos next line len rec bytes
    local -a ends
    _vigil_logs_ckpath "$file"
    _vigil_logs_ckread
    offset=$_ck_offset
    if [ "$_ck_state" = bad ]; then
        _vigil_logs_gap checkpoint_reset 0 "$file"
        _fp_crc='' _fp_n=0
    elif [ "$_ck_state" = ok ]; then
        # Nothing changed: the file need not even be opened.
        [ "$size" -eq "$_ck_size" ] && [ "$offset" -ge "$size" ] && return 0
        _vigil_logs_fingerprint "$path" "$_ck_n"
        if [ "$offset" -gt "$size" ] || [ "$_fp_crc" != "$_ck_crc" ]; then
            _vigil_logs_gap replaced "$offset" "$file"
            offset=0
        fi
    fi
    _vigil_logs_output_for_file "$file"
    while [ "$offset" -lt "$size" ]; do
        [ "$_vl_read" -lt "$_vl_max" ] || return 1
        [ $(($(date '+%s') - _vl_now)) -lt "$VIGIL_LOGS_RUN_SECS" ] || return 1
        pos=$offset
        _vl_batch=''
        _vl_n=0
        bytes=0
        ends=()
        while IFS= read -r line; do
            next=$((pos + ${#line} + 1))
            vigil_logs_record "$file" "$line"
            if [ -n "$_vl_rec" ]; then
                len=${#_vl_rec}
                if [ "$_vl_n" -gt 0 ] && { [ "$_vl_n" -ge "$_vl_lines" ] || [ $((bytes + len)) -gt "$_vl_bytes" ]; }; then
                    break
                fi
                _vl_batch=$_vl_batch${_vl_batch:+,}$_vl_rec
                _vl_n=$((_vl_n + 1))
                bytes=$((bytes + len))
                ends[${#ends[@]}]=$next
            fi
            pos=$next
        done < <(tail -c +$((offset + 1)) "$path")
        # Only an incomplete last line left: it waits for the next run.
        [ "$pos" -gt "$offset" ] || break
        if [ "$_vl_n" -gt 0 ]; then
            if _vigil_logs_send; then
                _vl_sent=$((_vl_sent + _vl_n))
                _vl_sent_bytes=$((_vl_sent_bytes + bytes))
            else
                if [ "$_vl_accepted" -gt 0 ]; then
                    offset=${ends[_vl_accepted - 1]}
                    _vl_sent=$((_vl_sent + _vl_accepted))
                    _vigil_logs_fingerprint "$path" 64
                    _vigil_logs_ckwrite "$file" "$offset" "$size"
                fi
                return 1
            fi
        fi
        _vl_read=$((_vl_read + pos - offset))
        offset=$pos
        _vigil_logs_fingerprint "$path" 64
        [ "$size" -ge "$offset" ] || size=$offset
        _vigil_logs_ckwrite "$file" "$offset" "$size"
    done
    return 0
}

# Sets _vl_output for the job a log file belongs to.
_vigil_logs_output_for_file() {
    case $1 in
        jobs/*)
            local job=${1#jobs/}
            vigil_logs_output_for "${job%%/*}"
            ;;
    esac
}

vigil_logs() {
    local dest type endpoint timeout hname hvalue f file size failures=0 next_try=0 prev='' line n next pending ok=1
    _vl_now=$(date '+%s')
    _vl_dir="$_vw_statedir/logs"
    _vl_events=()
    _vl_failed=''
    _vl_sent=0
    _vl_sent_bytes=0
    _vl_read=0
    _vl_header=''
    mkdir -p "$_vl_dir" "$_vw_spooldir/incoming"
    _vigil_fetch_tags
    vigil_logs_settings

    _vigil_wk_get log_forward destination ''
    dest=$_vw_value
    _vigil_wk_get log_forward batch_lines 500
    _vl_lines=$_vw_value
    _vigil_wk_get log_forward batch_kb 512
    _vl_bytes=$((_vw_value * 1024))
    _vigil_wk_get log_forward max_pending_mb 64
    _vl_max=$((_vw_value * 1048576))
    _vigil_wk_get "log_destination.$dest" endpoint ''
    endpoint=$_vw_value
    _vigil_wk_get "log_destination.$dest" timeout 10s
    _vigil_wk_secs "$_vw_value"
    _vl_secs=$_vw_secs
    _vigil_wk_get "log_destination.$dest" header_name ''
    hname=$_vw_value
    _vigil_wk_get "log_destination.$dest" header_value ''
    hvalue=$_vw_value
    _vl_url=$endpoint
    _vl_host=${endpoint#*://}
    _vl_host=${_vl_host%%/*}
    _vl_meta=0
    case $endpoint in
        http://*) _vl_meta=1 ;;
    esac

    if [ -f "$_vl_dir/forwarder.state" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case $line in
                'destination = '*) prev=${line#*= } ;;
                'failures = '*) failures=${line#*= } ;;
                'next_try = '*) next_try=${line#*= } ;;
            esac
        done < "$_vl_dir/forwarder.state"
    fi

    # The active revision (16.5).
    if [ -n "$_vw_config" ] && vigil_active_read "$_vw_statedir"; then
        _vl_revision=$VIGIL_ACT_REVISION
    else
        _vl_revision=$(printf 'config %s\n' "$(_vigil_fetch_digest < "$_vw_root/config/vigil.config")" | _vigil_fetch_digest)
        _vl_revision=${_vl_revision:0:12}
    fi
    _vigil_logs_resource

    _vigil_logs_list "$_vw_logdir"

    # Files retention deleted: what was not delivered is gone (13.4.4).
    for f in "$_vl_dir"/*.checkpoint; do
        [ -f "$f" ] || continue
        _vl_ck=$f
        _vigil_logs_ckread
        [ -n "$_ck_file" ] || continue
        file=${_ck_file#logs/}
        if [ ! -f "$_vw_logdir/$file" ]; then
            if [ "$_ck_state" = ok ] && [ "$_ck_size" -gt "$_ck_offset" ]; then
                _vigil_logs_gap deleted $((_ck_size - _ck_offset)) "$file"
            fi
            rm -f "$f"
        fi
    done

    # A new destination starts from the end of every file (13.4.4).
    if [ -n "$prev" ] && [ "$prev" != "$dest" ]; then
        n=0
        while IFS=$'\t' read -r file size; do
            [ -n "$file" ] || continue
            _vigil_logs_ckpath "$file"
            _vigil_logs_ckread
            n=$((n + size - _ck_offset))
            _vigil_logs_fingerprint "$_vw_logdir/$file" 64
            _vigil_logs_ckwrite "$file" "$size" "$size"
        done <<EOF
$_vl_list
EOF
        [ "$n" -gt 0 ] || n=0
        _vigil_logs_gap destination_changed "$n"
        failures=0 next_try=0
    fi

    if [ "$_vl_now" -ge "$next_try" ]; then
        if [ -n "$hname" ]; then
            if ! vigil_secret_resolve "$_vw_root" "$hvalue"; then
                _vigil_logs_failed auth "header_value $hvalue unavailable: $VIGIL_SECRET_WHY"
                ok=0
            else
                case $VIGIL_SECRET_VALUE in
                    *[[:cntrl:]]*)
                        _vigil_logs_failed auth "header_value $hvalue holds a control character"
                        ok=0
                        ;;
                    *) _vl_header="$hname: $VIGIL_SECRET_VALUE" ;;
                esac
                VIGIL_SECRET_VALUE=''
            fi
        fi
        if [ "$ok" -eq 1 ]; then
            while IFS=$'\t' read -r file size; do
                [ -n "$file" ] || continue
                _vigil_logs_file "$file" "$size" || break
            done <<EOF
$_vl_list
EOF
        fi
        _vl_header=''
        if [ -n "$_vl_failed" ]; then
            failures=$((failures + 1))
            # Exponential backoff, capped at 15 minutes (13.4.5).
            next=5
            n=1
            while [ "$n" -lt "$failures" ] && [ "$next" -lt 900 ]; do next=$((next * 2)); n=$((n + 1)); done
            [ "$next" -gt 900 ] && next=900
            next_try=$((_vl_now + next))
        else
            failures=0
            next_try=0
        fi
    fi

    # What is left, for the health metrics (13.4.6) and the supervisor.
    pending=0
    vigil_logs_total "$_vw_logdir"
    while IFS=$'\t' read -r file size; do
        [ -n "$file" ] || continue
        _vigil_logs_ckpath "$file"
        _vigil_logs_ckread
        [ "$size" -le "$_ck_offset" ] || pending=$((pending + size - _ck_offset))
    done <<EOF
$_vl_list
EOF
    if [ "$_vl_sent" -gt 0 ]; then
        _vl_events[${#_vl_events[@]}]="$_vl_now vigil.logs.records_sent $_vl_sent count $_vf_tags"
        _vl_events[${#_vl_events[@]}]="$_vl_now vigil.logs.bytes_sent $_vl_sent_bytes count $_vf_tags"
    fi
    _vl_events[${#_vl_events[@]}]="$_vl_now vigil.logs.pending_bytes $pending gauge $_vf_tags"
    f="$_vw_spooldir/incoming/$_vl_now-vigil_logs.events"
    printf '%s\n' "${_vl_events[@]}" > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
    {
        printf '[forwarder]\n'
        printf 'destination = %s\n' "$dest"
        printf 'failures = %s\n' "$failures"
        printf 'next_try = %s\n' "$next_try"
        printf 'checked_epoch = %s\n' "$_vl_now"
        printf 'total = %s\n' "$_vl_total"
    } > "$_vl_dir/forwarder.state.tmp.$$" && mv -f "$_vl_dir/forwarder.state.tmp.$$" "$_vl_dir/forwarder.state"
    if [ -n "$_vl_failed" ]; then
        _vw_reason="delivery to $dest failed: $_vl_failed"
        return 1
    fi
    return 0
}
