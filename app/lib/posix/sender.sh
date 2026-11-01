# shellcheck shell=bash
#
# Vigil sender - bash 3.2 compatible.
#
# The body of the vigil_sender worker (SPECIFICATION.md 4.5): fans spool
# files out to one queue per backend with the write-ahead protocol, keeps
# the spool within max_mb, and delivers each backend's queue in batches,
# backing off a failing backend without delaying the others.
#
#   vigil_send
#     Called by the worker after its claim, with the configuration parsed
#     and _vw_root, _vw_statedir, _vw_spooldir, _vw_host and _vw_os set.
#     Returns 0, or 1 with _vw_reason set when a backend failed.
#
# Backend types implemented so far: file, datadog and otel. Events for a
# backend of any other type are not queued; they are counted as dropped
# with reason=not_implemented, so the spool never fills with events that
# cannot be sent.
#
# Requires config.sh, effective.sh, worker.sh, prom.sh and backends.sh.

VIGIL_SEND_BATCH=500
VIGIL_SEND_TYPES=' file datadog otel '
# An HTTP backend's request: at most this many bytes of events, so the body
# stays within Datadog's 500 KB, and at most this many requests per run.
VIGIL_SEND_HTTP_BYTES=160000
VIGIL_SEND_HTTP_REQUESTS=10

# Enabled backends: _sd_ok (implemented) and _sd_todo (not yet), as
# space-separated names.
_vigil_send_backends() {
    local s name type
    _sd_ok='' _sd_todo=''
    s=0
    while [ "$s" -lt "${#VIGIL_CFG_SEC_NAME[@]}" ]; do
        name=${VIGIL_CFG_SEC_NAME[$s]}
        s=$((s + 1))
        case $name in backend.*) ;; *) continue ;; esac
        _vigil_wk_get "$name" enabled true
        [ "$_vw_value" = false ] && continue
        _vigil_wk_get "$name" type "${name#backend.}"
        case $VIGIL_SEND_TYPES in
            *" $_vw_value "*) _sd_ok="$_sd_ok ${name#backend.}" ;;
            *) _sd_todo="$_sd_todo ${name#backend.}" ;;
        esac
    done
}

_vigil_send_has() {
    case " $1 " in *" $2 "*) return 0 ;; esac
    return 1
}

# Counts dropped events: backend $1, reason $2, files $3... Totals per
# backend and reason are posted once, at the end of the run.
_vigil_send_drop() {
    local b=$1 reason=$2 f n=0 line
    shift 2
    for f in "$@"; do
        [ -f "$f" ] || continue
        while IFS= read -r line || [ -n "$line" ]; do n=$((n + 1)); done < "$f"
    done
    _vigil_send_dropn "$b" "$reason" "$n"
}

# Counts $3 dropped events for backend $1, reason $2.
_vigil_send_dropn() {
    local key="backend=$1 reason=$2" n=$3 i=0
    [ "$n" -gt 0 ] || return 0
    while [ "$i" -lt "${#_sd_dkey[@]}" ]; do
        if [ "${_sd_dkey[$i]}" = "$key" ]; then
            _sd_dnum[$i]=$((_sd_dnum[i] + n))
            return 0
        fi
        i=$((i + 1))
    done
    _sd_dkey[$i]=$key
    _sd_dnum[$i]=$n
}

# The backends spool file $1 goes to: the job's backends (6.6), or every
# enabled backend for Vigil's own events. Result in _sd_targets; backends
# not implemented yet are counted as dropped.
_vigil_send_targets() {
    local file=${1##*/} job list b
    job=${file#*-}
    job=${job%%-*}
    job=${job%.events}
    list=''
    vigil_config_section "job.$job"
    if [ "$VIGIL_CFG_SEC" -ge 0 ]; then
        vigil_config_effective "$job"
        local i=0
        while [ "$i" -lt "${#VIGIL_EFF_KEY[@]}" ]; do
            [ "${VIGIL_EFF_KEY[$i]}" = backends ] && list=${VIGIL_EFF_VALUE[$i]//,/ }
            i=$((i + 1))
        done
    else
        list="$_sd_ok $_sd_todo"
    fi
    _sd_targets=''
    for b in $list; do
        if _vigil_send_has "$_sd_ok" "$b"; then
            _sd_targets="$_sd_targets $b"
        elif _vigil_send_has "$_sd_todo" "$b"; then
            _vigil_send_drop "$b" not_implemented "$1"
        fi
    done
}

# Places fanout file $1 in every target queue not yet marked done, then
# retires it (4.5, steps 3 and 4).
_vigil_send_place() {
    local f=$1 base=${1##*/} b
    while read -r b || [ -n "$b" ]; do
        [ -n "$b" ] || continue
        [ -e "$f.$b.done" ] && continue
        if ! _vigil_send_has "$_sd_ok" "$b"; then
            # The backend was removed or disabled since the targets were fixed.
            _vigil_send_drop "$b" backend_removed "$f"
            : > "$f.$b.done"
            continue
        fi
        mkdir -p "$_sd_be/$b"
        cp "$f" "$_sd_be/$b/.$base.tmp.$$" && mv -f "$_sd_be/$b/.$base.tmp.$$" "$_sd_be/$b/$base" && : > "$f.$b.done"
    done < "$f.targets"
    rm -f "$f" "$f.targets" "$f".*.done
}

# Records backend $1's failure, $2 saying why, and backs it off.
_vigil_send_failed() {
    local b=$1 sfile="$_vw_statedir/backends/$1.state" failures=0 next n line
    if [ -f "$sfile" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case $line in 'failures = '*) failures=${line#*= } ;; esac
        done < "$sfile"
    fi
    failures=$((failures + 1))
    # Exponential backoff, capped at 5 minutes (4.5).
    next=5
    n=1
    while [ "$n" -lt "$failures" ] && [ "$next" -lt 300 ]; do next=$((next * 2)); n=$((n + 1)); done
    [ "$next" -gt 300 ] && next=300
    mkdir -p "$_vw_statedir/backends"
    printf '[backend]\nfailures = %s\nnext_try = %s\n' "$failures" "$((_sd_epoch + next))" > "$sfile.tmp.$$" && mv -f "$sfile.tmp.$$" "$sfile"
    _sd_events[${#_sd_events[@]}]="$_sd_epoch vigil.backend.failures 1 count $_sd_tags backend=$b"
    _sd_failed="$_sd_failed${_sd_failed:+, }$b ($2)"
}

# Delivers HTTP backend $1 of type $2: batches of at most
# VIGIL_SEND_HTTP_BYTES, oldest first, until the queue is empty, a request
# fails or VIGIL_SEND_HTTP_REQUESTS were made.
_vigil_send_http() {
    local b=$1 type=$2 q="$_sd_be/$1" requests=0 f size name total reason count sizes
    local -a cand batch
    while [ "$requests" -lt "$VIGIL_SEND_HTTP_REQUESTS" ]; do
        cand=()
        for f in "$q"/*.events; do
            [ -f "$f" ] || continue
            cand[${#cand[@]}]=$f
            [ "${#cand[@]}" -ge "$VIGIL_SEND_BATCH" ] && break
        done
        [ "${#cand[@]}" -gt 0 ] || return 0
        batch=()
        total=0
        sizes=$(wc -c -- "${cand[@]}")
        while read -r size name; do
            [ -f "$name" ] || continue
            [ "${#batch[@]}" -gt 0 ] && [ $((total + size)) -gt "$VIGIL_SEND_HTTP_BYTES" ] && break
            batch[${#batch[@]}]=$name
            total=$((total + size))
        done <<EOF
$sizes
EOF
        requests=$((requests + 1))
        if ! vigil_backend_send "$_vw_root" "$b" "$type" "${batch[@]}"; then
            _vigil_send_failed "$b" "$_vb_why"
            return 1
        fi
        while read -r reason count; do
            [ -n "$reason" ] && _vigil_send_dropn "$b" "$reason" "$count"
        done <<EOF
$_vb_drops
EOF
        rm -f "${batch[@]}" "$_vw_statedir/backends/$b.state"
    done
}

# Delivers backend $1's queue, oldest first.
_vigil_send_deliver() {
    local b=$1 q="$_sd_be/$1" sfile="$_vw_statedir/backends/$1.state" next=0 line f n=0 path tmp
    local -a batch
    [ -d "$q" ] || return 0
    if [ -f "$sfile" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case $line in 'next_try = '*) next=${line#*= } ;; esac
        done < "$sfile"
    fi
    [ "$_sd_epoch" -lt "$next" ] && return 0
    _vigil_wk_get "backend.$b" type "$b"
    if [ "$_vw_value" != file ]; then
        _vigil_send_http "$b" "$_vw_value"
        return 0
    fi
    batch=()
    for f in "$q"/*.events; do
        [ -f "$f" ] || continue
        batch[${#batch[@]}]=$f
        n=$((n + 1))
        [ "$n" -ge "$VIGIL_SEND_BATCH" ] && break
    done
    [ "$n" -gt 0 ] || return 0

    # file: merge the batch into the Prometheus text file, atomically.
    _vigil_wk_get "backend.$b" path metrics/vigil.prom
    case $_vw_value in /*) path=$_vw_value ;; *) path="$_vw_root/$_vw_value" ;; esac
    tmp="$path.tmp.$$"
    if mkdir -p "${path%/*}" && vigil_prom_merge "$path" "${batch[@]}" > "$tmp" && mv -f "$tmp" "$path"; then
        rm -f "${batch[@]}"
        rm -f "$sfile"
    else
        rm -f "$tmp"
        _vigil_send_failed "$b" "cannot write $path"
    fi
}

vigil_send() {
    local f b sizes line size name total=0 max when i
    local -a files fsizes
    _sd_in="$_vw_spooldir/incoming"
    _sd_fan="$_vw_spooldir/fanout"
    _sd_be="$_vw_spooldir/backends"
    _sd_epoch=$(date '+%s')
    _sd_events=()
    _sd_dkey=()
    _sd_dnum=()
    _sd_failed=''
    mkdir -p "$_sd_in" "$_sd_fan" "$_sd_be"
    _vigil_wk_get vigil instance vigil
    _sd_tags="host=$_vw_host os=$_vw_os instance=$_vw_value"
    vigil_config_section tags
    if [ "$VIGIL_CFG_SEC" -ge 0 ]; then
        i=${VIGIL_CFG_SEC_FIRST[$VIGIL_CFG_SEC]}
        while [ "$i" -lt $((VIGIL_CFG_SEC_FIRST[VIGIL_CFG_SEC] + VIGIL_CFG_SEC_COUNT[VIGIL_CFG_SEC])) ]; do
            _sd_tags="$_sd_tags ${VIGIL_CFG_KEY[$i]}=${VIGIL_CFG_VALUE[$i]}"
            i=$((i + 1))
        done
    fi
    _vigil_send_backends

    # Unfinished fan-outs first, then new files (4.5).
    for f in "$_sd_fan"/*.events; do
        [ -f "$f" ] || continue
        if [ ! -f "$f.targets" ]; then
            _vigil_send_targets "$f"
            printf '%s\n' $_sd_targets > "$f.targets.tmp.$$" && mv -f "$f.targets.tmp.$$" "$f.targets"
        fi
        _vigil_send_place "$f"
    done
    for f in "$_sd_in"/*.events; do
        [ -f "$f" ] || continue
        mv "$f" "$_sd_fan/${f##*/}" || continue
        f="$_sd_fan/${f##*/}"
        _vigil_send_targets "$f"
        printf '%s\n' $_sd_targets > "$f.targets.tmp.$$" && mv -f "$f.targets.tmp.$$" "$f.targets"
        _vigil_send_place "$f"
    done

    # Queues of removed or disabled backends are discarded.
    for f in "$_sd_be"/*; do
        [ -d "$f" ] || continue
        b=${f##*/}
        _vigil_send_has "$_sd_ok" "$b" && continue
        _vigil_send_drop "$b" backend_removed "$f"/*.events
        rm -rf "$f"
    done

    # The spool size cap: drop the oldest (or newest) queued files until the
    # queues fit in max_mb (4.5).
    _vigil_wk_get spool max_mb 100
    max=$((_vw_value * 1048576))
    _vigil_wk_get spool when_full drop_oldest
    when=$_vw_value
    files=() fsizes=()
    sizes=$(cd "$_sd_be" && wc -c -- */*.events 2>/dev/null)
    while read -r size name; do
        [ "$name" = total ] && continue
        [ -n "$name" ] || continue
        files[${#files[@]}]=$name
        fsizes[${#fsizes[@]}]=$size
        total=$((total + size))
    done <<EOF
$sizes
EOF
    if [ "$total" -gt "$max" ]; then
        # Queue file names start with their epoch, so a name sort is oldest first.
        local order
        order=$(i=0; while [ "$i" -lt "${#files[@]}" ]; do printf '%s %s %s\n' "${files[$i]##*/}" "${files[$i]}" "${fsizes[$i]}"; i=$((i + 1)); done | LC_ALL=C sort)
        [ "$when" = drop_newest ] && order=$(printf '%s\n' "$order" | LC_ALL=C sort -r)
        while read -r line name size; do
            [ "$total" -gt "$max" ] || break
            [ -n "$name" ] || continue
            _vigil_send_drop "${name%%/*}" spool_full "$_sd_be/$name"
            rm -f "$_sd_be/$name"
            total=$((total - size))
        done <<EOF
$order
EOF
    fi

    for b in $_sd_ok; do
        _vigil_send_deliver "$b"
    done

    # The spool's own size, after delivery, and the sender's events: they are
    # delivered by the next run.
    size=$(cat "$_sd_be"/*/*.events "$_sd_in"/*.events 2>/dev/null | wc -c)
    _sd_events[${#_sd_events[@]}]="$_sd_epoch vigil.spool.bytes $((size + 0)) gauge $_sd_tags"
    i=0
    while [ "$i" -lt "${#_sd_dkey[@]}" ]; do
        _sd_events[${#_sd_events[@]}]="$_sd_epoch vigil.spool.dropped ${_sd_dnum[$i]} count $_sd_tags ${_sd_dkey[$i]}"
        i=$((i + 1))
    done
    f="$_sd_in/$_sd_epoch-vigil_sender.events"
    i=0
    while [ "$i" -lt "${#_sd_events[@]}" ]; do
        printf '%s\n' "${_sd_events[$i]}"
        i=$((i + 1))
    done > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"

    if [ -n "$_sd_failed" ]; then
        _vw_reason="delivery failed: $_sd_failed"
        return 1
    fi
    return 0
}
