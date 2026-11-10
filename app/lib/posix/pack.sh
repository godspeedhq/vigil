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
# Vigil packs - bash 3.2 compatible.
#
# A pack is a set of scripts and jobs (SPECIFICATION.md 18.10), kept in the
# Vigil repository and carried by each release, signed with it. packs/<name>/
# holds this platform's scripts and is Vigil's to replace. The configuration
# is the operator's: Vigil runs only what it names, so an update changes
# scripts and never the configuration, and a new script stays off until it is
# enabled. Must behave exactly as Pack.ps1.
#
#   vigil_pack_list <root>
#     Each pack here and whether its jobs are on.
#   vigil_pack_enable <root> <pack, or pack_job>
#   vigil_pack_disable <root> <pack, or pack_job>
#     Change the configuration, or nothing when the result is not valid.
#   vigil_pack_update <root> <app dir> <check: 0|1>
#     Replaces the scripts with the latest release's.
#   vigil_pack_seed <root> <app dir>
#     A packaged program only: copies in the packs the package keeps beside
#     app/, those not here yet.
#   Each returns 0, or 1 with the reason on stderr; nothing is changed then.
#
# Requires config.sh, validate.sh, worker.sh and selfupdate.sh.

_vigil_pack_die() {
    printf 'vigil: %s\n' "$*" >&2
    return 1
}

_vigil_pack_start() { printf '# pack %s: vigil pack disable takes these out\n' "$1"; }
_vigil_pack_end() { printf '# end of pack %s\n' "$1"; }

_vigil_pack_os() {
    case $(uname -s) in
        Darwin) _vp_os=macos ;;
        *) _vp_os=linux ;;
    esac
}

# The first packs of a packaged program (18.6), from the packs/ folder the
# package keeps beside app/. The install script copies them itself, from the
# archive. A pack already in the root stays as it is, so this never undoes a
# vigil pack update.
vigil_pack_seed() {
    local root=$1 src p
    vigil_packaged "$2" || return 0
    src=${2%/app}/packs
    [ -d "$src" ] || return 0
    _vigil_pack_os
    for p in "$src"/*/; do
        [ -f "$p/pack.config" ] || continue
        p=${p%/}
        [ ! -e "$root/packs/${p##*/}" ] || continue
        mkdir -p "$root/packs/${p##*/}" && cp "$p/pack.config" "$root/packs/${p##*/}/" ||
            { _vigil_pack_die "cannot write to $root/packs"; return 1; }
        if [ -d "$p/$_vp_os" ]; then
            cp "$p/$_vp_os"/* "$root/packs/${p##*/}/" || { _vigil_pack_die "cannot write to $root/packs"; return 1; }
        fi
        # The service account has to read them.
        chmod -R a+rX "$root/packs/${p##*/}"
    done
    return 0
}

# A key of a parsed section, into _vp_value.
_vigil_pack_get() {
    local i=${VIGIL_CFG_SEC_FIRST[$1]} end=$((VIGIL_CFG_SEC_FIRST[$1] + VIGIL_CFG_SEC_COUNT[$1]))
    _vp_value=''
    while [ "$i" -lt "$end" ]; do
        if [ "${VIGIL_CFG_KEY[$i]}" = "$2" ]; then _vp_value=${VIGIL_CFG_VALUE[$i]}; fi
        i=$((i + 1))
    done
}

# Reads manifest $1/pack.config of pack $2: _vp_version, _vp_vigil and _vp_about,
# _vp_needs (its needs lines, one per line), and in _vp_jobs the jobs with a
# script here, in order, each with its section in _vp_section_<job>. Returns 1
# when it cannot be read.
_vigil_pack_read() {
    local dir=$1 name=$2 j=0 sec job text i end
    _vp_version='' _vp_vigil='' _vp_about='' _vp_jobs='' _vp_needs=''
    [ -f "$dir/pack.config" ] || return 1
    vigil_config_parse "$dir/pack.config" || return 1
    while [ "$j" -lt "${#VIGIL_CFG_SEC_NAME[@]}" ]; do
        sec=${VIGIL_CFG_SEC_NAME[$j]}
        case $sec in
            pack)
                _vigil_pack_get "$j" version
                _vp_version=$_vp_value
                _vigil_pack_get "$j" vigil
                _vp_vigil=$_vp_value
                _vigil_pack_get "$j" description
                _vp_about=$_vp_value
                i=${VIGIL_CFG_SEC_FIRST[$j]}
                end=$((i + VIGIL_CFG_SEC_COUNT[j]))
                while [ "$i" -lt "$end" ]; do
                    [ "${VIGIL_CFG_KEY[$i]}" = needs ] && _vp_needs="$_vp_needs${VIGIL_CFG_VALUE[$i]}"$'\n'
                    i=$((i + 1))
                done
                ;;
            job.*)
                job=${sec#job.}
                if [ -f "$dir/$job.sh" ]; then
                    text="[job.${name}_$job]"$'\n'"file = packs/$name/$job.sh"$'\n'
                    i=${VIGIL_CFG_SEC_FIRST[$j]}
                    end=$((i + VIGIL_CFG_SEC_COUNT[j]))
                    while [ "$i" -lt "$end" ]; do
                        case ${VIGIL_CFG_KEY[$i]} in
                            metrics | file) ;;
                            *) text="$text${VIGIL_CFG_KEY[$i]} = ${VIGIL_CFG_VALUE[$i]}"$'\n' ;;
                        esac
                        i=$((i + 1))
                    done
                    _vp_jobs="$_vp_jobs $job"
                    printf -v "_vp_section_$job" '%s' "$text"
                fi
                ;;
        esac
        j=$((j + 1))
    done
    [ -n "$_vp_version" ]
}

# Finds the latest release and puts this platform's packs in _vp_src, verified:
# the signature against the key installed here, then the file against
# SHA256SUMS. From GitHub, or the configuration's release_url. The caller
# removes _vp_work.
_vigil_pack_fetch() {
    local root=$1 app=$2 base tag want file f key sum got why
    local -a curlopts
    vigil_config_version "$root"
    vigil_release_source || return 1
    base=$_vu_base
    curlopts=("${_vu_curl[@]}" --max-time 60)
    [ "$_vu_mirror" = 2 ] || command -v curl > /dev/null 2>&1 || { _vigil_pack_die 'curl not found'; return 1; }
    command -v openssl > /dev/null 2>&1 || { _vigil_pack_die 'openssl not found: packs cannot be verified; nothing was changed'; return 1; }
    key=$app/release-key.pem
    [ -n "${VIGIL_TEST_RELEASE_URL-}" ] && [ -n "${VIGIL_TEST_RELEASE_KEY-}" ] && key=$VIGIL_TEST_RELEASE_KEY
    [ -f "$key" ] || { _vigil_pack_die 'no release key here: packs cannot be verified; nothing was changed'; return 1; }
    want=$(vigil_latest_version "$base" "$_vu_mirror" "${curlopts[@]}") ||
        { _vigil_pack_die "$(_vigil_release_unreadable)"; return 1; }
    _vigil_pack_os
    _vp_work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-pack.XXXXXX") || { _vigil_pack_die 'cannot make a temporary folder'; return 1; }
    file=vigil-packs-$want-$_vp_os.tar.gz
    for f in "$file" SHA256SUMS SHA256SUMS.sig; do
        if ! vigil_release_get "$base" "$_vu_mirror" "releases/download/v$want/$f" "$_vp_work/$f" "${curlopts[@]}" 2> /dev/null; then
            why=$(_vigil_release_refused "releases/download/v$want/$f")
            _vigil_pack_die "cannot download the packs of release $want${why:+: $why}"
            return 1
        fi
    done
    if ! openssl dgst -sha256 -verify "$key" -signature "$_vp_work/SHA256SUMS.sig" "$_vp_work/SHA256SUMS" > /dev/null 2>&1; then
        _vigil_pack_die "release $want is not signed by the Vigil release key; nothing was changed"
        return 1
    fi
    sum=$(awk -v f="$file" '$2 == f || $2 == "*" f { print $1 }' "$_vp_work/SHA256SUMS")
    got=$(_vigil_self_sha "$_vp_work/$file")
    if [ -z "$sum" ] || [ "$got" != "$sum" ]; then
        _vigil_pack_die "the packs of release $want do not match its SHA256SUMS; nothing was changed"
        return 1
    fi
    mkdir "$_vp_work/x" && tar --no-same-owner -xzf "$_vp_work/$file" -C "$_vp_work/x" 2> /dev/null ||
        { _vigil_pack_die "cannot unpack the packs of release $want"; return 1; }
    _vp_src=$_vp_work/x/vigil-packs-$want
    [ -d "$_vp_src" ] || { _vigil_pack_die "the packs of release $want hold no vigil-packs-$want folder"; return 1; }
    _vp_want=$want
}

# What may stop an edit of the configuration.
_vigil_pack_writable() {
    local root=$1 cfg=$1/config/vigil.config
    [ -f "$cfg" ] || { _vigil_pack_die 'no configuration here: run vigil init first'; return 1; }
    vigil_config_parse "$cfg" || { _vigil_pack_die "$cfg has errors: fix them first (vigil precheck)"; return 1; }
    _vigil_wk_get vigil config_source ''
    if [ -n "$_vw_value" ]; then
        _vigil_pack_die "the configuration comes from [source.$_vw_value]: add the pack's jobs there"
        return 1
    fi
    if [ ! -w "$cfg" ]; then
        _vigil_pack_die "$cfg is not writable: run this as the account that installed Vigil (sudo for a system install)"
        return 1
    fi
}

# Whether the configuration now in place is good for pack $2, judged by its own
# jobs, so a problem that was already there stops nothing. The reason is in
# _vp_why.
_vigil_pack_valid() {
    local cfg=$1/config/vigil.config name=$2 i=0
    _vp_why=''
    if ! vigil_config_parse "$cfg"; then
        _vp_why=${VIGIL_CFG_ERRORS[0]#*	}
        return 1
    fi
    vigil_config_validate
    while [ "$i" -lt "${#VIGIL_VAL_KIND[@]}" ]; do
        case ${VIGIL_VAL_KIND[$i]}:${VIGIL_VAL_JOB[$i]} in
            ERROR:* | INVALID:"$name"_*)
                _vp_why="${VIGIL_VAL_MSG[$i]} (${VIGIL_VAL_CODE[$i]})"
                return 1
                ;;
        esac
        i=$((i + 1))
    done
}

# The configuration with pack $2's block changed, on standard output: jobs $3
# are added and jobs $4 taken out, or the block goes when $4 is "all". Every
# other section stays as it is.
_vigil_pack_rewrite() {
    local cfg=$1 name=$2 add=$3 drop=$4 start end line bare in=0 keep=1 job found=0 j var
    start=$(_vigil_pack_start "$name")
    end=$(_vigil_pack_end "$name")
    while IFS= read -r line || [ -n "$line" ]; do
        bare=${line%$'\r'}
        if [ "$in" -eq 0 ]; then
            if [ "$bare" = "$start" ]; then
                in=1
                keep=1
                found=1
                [ "$drop" = all ] || printf '%s\n' "$line"
            else
                printf '%s\n' "$line"
            fi
            continue
        fi
        if [ "$bare" = "$end" ]; then
            in=0
            if [ "$drop" != all ]; then
                for j in $add; do
                    var=_vp_section_$j
                    printf '\n%s' "${!var}"
                done
                printf '%s\n' "$line"
            fi
            continue
        fi
        [ "$drop" != all ] || continue
        case $bare in
            "[job.${name}_"*)
                job=${bare#\[job."$name"_}
                job=${job%%]*}
                keep=1
                case " $drop " in *" $job "*) keep=0 ;; esac
                ;;
        esac
        [ "$keep" -eq 0 ] || printf '%s\n' "$line"
    done < "$cfg"
    if [ "$found" -eq 0 ] && [ -n "$add" ]; then
        printf '\n'
        _vigil_pack_start "$name"
        for j in $add; do
            var=_vp_section_$j
            printf '\n%s' "${!var}"
        done
        _vigil_pack_end "$name"
    fi
}

# Whether job $1 is in the parsed configuration.
_vigil_pack_on() {
    vigil_config_section "job.$1"
    [ "$VIGIL_CFG_SEC" -ge 0 ]
}

# Splits $2 into a pack here and, if it names one job, that job: _vp_pack and
# _vp_job. Returns 1 when there is no such pack.
_vigil_pack_name() {
    local root=$1 what=$2 d n
    case $what in
        '' | *[!a-z0-9_]*) _vigil_pack_die "not a pack or job name: $what"; return 1 ;;
    esac
    _vp_pack='' _vp_job=''
    if [ -f "$root/packs/$what/pack.config" ]; then
        _vp_pack=$what
        return 0
    fi
    for d in "$root"/packs/*/; do
        n=${d%/}
        n=${n##*/}
        case $what in
            "${n}"_*)
                _vp_pack=$n
                _vp_job=${what#"${n}"_}
                return 0
                ;;
        esac
    done
    _vigil_pack_die "no pack or job called $what: vigil pack list"
    return 1
}

# Writes the configuration in $3, goes back when the result is not valid.
_vigil_pack_apply() {
    local root=$1 name=$2 new=$3 cfg=$1/config/vigil.config before=$3.before
    cp "$cfg" "$before" || return 1
    # Into the same file: its owner and mode stay.
    cat "$new" > "$cfg"
    if ! _vigil_pack_valid "$root" "$name"; then
        cat "$before" > "$cfg"
        rm -f "$new" "$before"
        _vigil_pack_die "the configuration would not be valid: $_vp_why; nothing was changed"
        return 1
    fi
    rm -f "$new" "$before"
}

# Whether secret reference $2 can be had, as far as can be told here without
# reading it, in _vp_state. A store is not asked: that is precheck's to do.
_vigil_pack_secret() {
    local d=$1/config/secrets n
    case $2 in
        secret:*)
            n=${2#secret:}
            if [ -d "$d" ] && { [ ! -r "$d" ] || [ ! -x "$d" ]; }; then
                _vp_state='cannot be told from this account: vigil precheck, as the account Vigil runs as'
            elif [ -e "$d/$n" ]; then
                _vp_state=set
            else
                _vp_state="not set: vigil secret set $n, as the account Vigil runs as"
            fi
            ;;
        env:*) _vp_state='from the environment Vigil runs in' ;;
        *) _vp_state='from a secret store: vigil precheck checks it' ;;
    esac
}

# What pack $2's jobs in the parsed configuration need, one line each after
# lead $3: each secret they name and whether it is there, the pack's own
# needs (_vp_needs, from _vigil_pack_read), and their settings (env, never a
# secret). So a pack is never turned on blind.
_vigil_pack_needs() {
    local root=$1 name=$2 lead=$3 i job value seen=' ' envs='' line
    i=0
    while [ "$i" -lt "${#VIGIL_CFG_KEY[@]}" ]; do
        job=${VIGIL_CFG_SECTION[$i]#job."$name"_}
        if [ "$job" != "${VIGIL_CFG_SECTION[$i]}" ] && case " $_vp_jobs " in *" $job "*) true ;; *) false ;; esac; then
            value=${VIGIL_CFG_VALUE[$i]}
            case ${VIGIL_CFG_KEY[$i]} in
                secret)
                    value=${value#*=}
                    case $seen in *" $value "*) ;; *)
                        seen="$seen$value "
                        _vigil_pack_secret "$root" "$value"
                        printf '%sneeds %s: %s\n' "$lead" "$value" "$_vp_state"
                        ;;
                    esac
                    ;;
                env)
                    case "$envs " in *" $value "*) ;; *) envs="$envs $value" ;; esac
                    ;;
            esac
        fi
        i=$((i + 1))
    done
    while IFS= read -r line; do
        [ -n "$line" ] && printf '%sneeds %s\n' "$lead" "$line"
    done << EOF
$_vp_needs
EOF
    [ -z "$envs" ] || printf '%ssettings in vigil.config:%s\n' "$lead" "$envs"
}

vigil_pack_list() {
    local root=$1 d name j n=0 state
    for d in "$root"/packs/*/; do
        [ -f "$d/pack.config" ] || continue
        name=${d%/}
        name=${name##*/}
        _vigil_pack_read "$d" "$name" || continue
        printf '%s %s: %s\n' "$name" "$_vp_version" "$_vp_about"
        vigil_config_parse "$root/config/vigil.config" 2> /dev/null
        for j in $_vp_jobs; do
            state=off
            _vigil_pack_on "${name}_$j" && state=on
            printf '  %-24s %s\n' "${name}_$j" "$state"
        done
        _vigil_pack_needs "$root" "$name" '  '
        n=$((n + 1))
    done
    [ "$n" -gt 0 ] || printf 'no packs here\n'
    return 0
}

vigil_pack_enable() {
    local root=$1 what=$2 add='' j list new
    _vigil_pack_name "$root" "$what" || return 1
    _vigil_pack_writable "$root" || return 1
    _vigil_pack_read "$root/packs/$_vp_pack" "$_vp_pack" || { _vigil_pack_die "cannot read pack $_vp_pack"; return 1; }
    list=$_vp_jobs
    if [ -n "$_vp_job" ]; then
        case " $list " in
            *" $_vp_job "*) list=$_vp_job ;;
            *) _vigil_pack_die "no job called $what: vigil pack list"; return 1 ;;
        esac
    fi
    vigil_config_parse "$root/config/vigil.config"
    for j in $list; do
        _vigil_pack_on "${_vp_pack}_$j" || add="$add $j"
    done
    if [ -z "$add" ]; then
        printf '%s is already on\n' "$what"
        _vigil_pack_needs "$root" "$_vp_pack" ''
        return 0
    fi
    new=$root/config/.vigil.config.pack.$$
    _vigil_pack_rewrite "$root/config/vigil.config" "$_vp_pack" "$add" '' > "$new"
    _vigil_pack_apply "$root" "$_vp_pack" "$new" || return 1
    for j in $add; do printf 'on: %s_%s\n' "$_vp_pack" "$j"; done
    vigil_config_parse "$root/config/vigil.config"
    _vigil_pack_needs "$root" "$_vp_pack" ''
}

vigil_pack_disable() {
    local root=$1 what=$2 new drop
    _vigil_pack_name "$root" "$what" || return 1
    _vigil_pack_writable "$root" || return 1
    drop=all
    if [ -n "$_vp_job" ]; then
        _vigil_pack_on "$what" || { printf '%s is already off\n' "$what"; return 0; }
        drop=$_vp_job
    fi
    new=$root/config/.vigil.config.pack.$$
    _vigil_pack_rewrite "$root/config/vigil.config" "$_vp_pack" '' "$drop" > "$new"
    _vigil_pack_apply "$root" "$_vp_pack" "$new" || return 1
    printf 'off: %s\n' "$what"
}

# The jobs of the configuration that run a script of pack $2 missing from the
# release at $3, into _vp_kept; each script is copied to $4 so the job keeps
# working. Needs _vp_old, the installed pack.
_vigil_pack_keep() {
    local root=$1 name=$2 src=$3 to=$4 i=0 n f job
    _vp_kept=''
    vigil_config_parse "$root/config/vigil.config" 2> /dev/null || return 0
    n=${#VIGIL_CFG_KEY[@]}
    while [ "$i" -lt "$n" ]; do
        if [ "${VIGIL_CFG_KEY[$i]}" = file ]; then
            f=${VIGIL_CFG_VALUE[$i]}
            case ${VIGIL_CFG_SECTION[$i]}:$f in
                job.*:packs/"$name"/*)
                    f=${f#packs/"$name"/}
                    job=${VIGIL_CFG_SECTION[$i]#job.}
                    if [ ! -f "$src/$f" ] && [ -f "$_vp_old/$f" ]; then
                        cp "$_vp_old/$f" "$to/$f"
                        _vp_kept="$_vp_kept $job"
                    fi
                    ;;
            esac
        fi
        i=$((i + 1))
    done
}

# Replaces pack $3's scripts with those at $4, and says what changed.
_vigil_pack_replace() {
    local root=$1 app=$2 name=$3 src=$4 was=$5 dir=$1/packs/$3 changed='' fresh='' f b j old_jobs want_ver
    _vp_old=$dir
    _vigil_pack_read "$src" "$name" || return 1
    want_ver=$_vp_version
    if [ -f "$app/VERSION" ] && [ -n "$_vp_vigil" ] && _vigil_self_newer "$_vp_vigil" "$(cat "$app/VERSION")"; then
        _vigil_pack_die "pack $name needs Vigil $_vp_vigil or later: vigil self update"
        return 1
    fi
    fresh=$_vp_jobs
    if [ -f "$dir/pack.config" ]; then
        _vigil_pack_read "$dir" "$name"
        old_jobs=$_vp_jobs
    else
        old_jobs=''
    fi
    for f in "$src"/*.sh; do
        [ -f "$f" ] || continue
        b=${f##*/}
        if [ -f "$dir/$b" ] && [ "$(cksum < "$f")" != "$(cksum < "$dir/$b")" ]; then
            changed="$changed ${name}_${b%.sh}"
        fi
    done
    rm -rf "$dir.new" "$dir.old"
    cp -R "$src" "$dir.new" || { rm -rf "$dir.new"; _vigil_pack_die "cannot write to $root/packs; nothing was changed"; return 1; }
    chmod -R a+rX "$dir.new"
    _vigil_pack_keep "$root" "$name" "$src" "$dir.new"
    if [ -d "$dir" ]; then
        mv "$dir" "$dir.old" || { rm -rf "$dir.new"; _vigil_pack_die "cannot replace $dir; nothing was changed"; return 1; }
    fi
    if ! mv "$dir.new" "$dir"; then
        [ ! -d "$dir.old" ] || mv "$dir.old" "$dir"
        rm -rf "$dir.new"
        _vigil_pack_die "cannot replace $dir; nothing was changed"
        return 1
    fi
    rm -rf "$dir.old"
    if [ -n "$was" ]; then
        printf 'updated pack %s %s to %s\n' "$name" "$was" "$want_ver"
    else
        printf 'added pack %s %s\n' "$name" "$want_ver"
    fi
    [ -z "$changed" ] || printf 'changed:%s\n' "$changed"
    vigil_config_parse "$root/config/vigil.config" 2> /dev/null
    for j in $fresh; do
        case " $old_jobs " in
            *" $j "*) ;;
            *) _vigil_pack_on "${name}_$j" || printf 'new, not running: %s_%s. To turn it on: vigil pack enable %s_%s\n' "$name" "$j" "$name" "$j" ;;
        esac
    done
    for j in $_vp_kept; do
        printf 'dropped from the pack, still running: %s. To stop it: vigil pack disable %s\n' "$j" "$j"
    done
}

# Whether the installed packs can be read from this account: else what is
# here cannot be told, and every pack would look missing.
_vigil_pack_readable() {
    local root=$1 d
    if [ -e "$root/packs" ]; then
        [ -r "$root/packs" ] && [ -x "$root/packs" ] || return 1
        for d in "$root"/packs/*/; do
            [ -d "$d" ] || continue
            [ -r "$d" ] && [ -x "$d" ] || return 1
            [ ! -e "$d/pack.config" ] || [ -r "$d/pack.config" ] || return 1
        done
    else
        # No packs/, or a root this account cannot look into.
        [ -r "$root" ] && [ -x "$root" ] || return 1
    fi
}

vigil_pack_update() {
    local root=$1 app=$2 check=$3 d name was rc=0
    if ! _vigil_pack_readable "$root"; then
        _vigil_pack_die "cannot read $root/packs from this account: run this as the account that installed Vigil (sudo for a system install)"
        return 1
    fi
    if [ "$check" = 0 ] && ! { [ -w "$root/packs" ] || { [ ! -e "$root/packs" ] && [ -w "$root" ]; }; }; then
        _vigil_pack_die "$root/packs is not writable: run this as the account that installed Vigil (sudo for a system install)"
        return 1
    fi
    _vp_work=''
    _vigil_pack_fetch "$root" "$app" || { [ -z "$_vp_work" ] || rm -rf "$_vp_work"; return 1; }
    mkdir -p "$root/packs"
    for d in "$_vp_src"/*/; do
        [ -f "$d/pack.config" ] || continue
        d=${d%/}
        name=${d##*/}
        was=''
        if _vigil_pack_read "$root/packs/$name" "$name"; then was=$_vp_version; fi
        _vigil_pack_read "$d" "$name" || continue
        if [ "$_vp_version" = "$was" ]; then
            printf 'pack %s %s is here: nothing to do\n' "$name" "$was"
        elif [ "$check" = 1 ]; then
            printf 'pack %s %s is here; %s is available: vigil pack update\n' "$name" "${was:-none}" "$_vp_version"
        else
            _vigil_pack_replace "$root" "$app" "$name" "$d" "$was" || rc=1
        fi
    done
    rm -rf "$_vp_work"
    return "$rc"
}
