# shellcheck shell=bash
#
# Vigil packs - bash 3.2 compatible.
#
# A pack is a set of scripts and jobs from the vigil-packs releases
# (SPECIFICATION.md 18.10). A release holds every pack, signed with the Vigil
# release key. A pack lives in packs/<name>/, which is Vigil's to replace, and
# its jobs are a marked block in the configuration, which is the operator's
# to edit: an update keeps what is there, adds the pack's new jobs and takes
# out those it dropped. Must behave exactly as Pack.ps1.
#
#   vigil_pack_list <root>
#     What is added here.
#   vigil_pack_add <root> <app dir> <name>
#   vigil_pack_update <root> <app dir> <check: 0|1>
#   vigil_pack_remove <root> <name>
#     Each returns 0, or 1 with the reason on stderr; nothing is changed then.
#
# Requires config.sh, validate.sh, worker.sh and selfupdate.sh.

VIGIL_PACK_RELEASES=https://github.com/godspeedhq/vigil-packs

_vigil_pack_die() {
    printf 'vigil: %s\n' "$*" >&2
    return 1
}

_vigil_pack_start() { printf '# pack %s: added by vigil pack add; vigil pack remove takes it out\n' "$1"; }
_vigil_pack_end() { printf '# end of pack %s\n' "$1"; }

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
# and in _vp_jobs the jobs with a script for this platform, in order, each
# with its section in _vp_section_<job>. Returns 1 when it cannot be read.
_vigil_pack_read() {
    local dir=$1 name=$2 j=0 sec job text i end
    _vp_version='' _vp_vigil='' _vp_about='' _vp_jobs=''
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

# Finds the latest release and puts it in _vp_src, verified: the signature
# against the key installed here, then the archive against SHA256SUMS. The
# caller removes _vp_work.
_vigil_pack_fetch() {
    local app=$1 base=$VIGIL_PACK_RELEASES tag want file f key sum got
    local -a curlopts
    curlopts=(-q --proto =https --proto-redir =https --max-time 60)
    # Tests only (22.4.4): releases from a local server, never over the
    # network.
    if [ -n "${VIGIL_TEST_RELEASE_URL-}" ]; then
        case $VIGIL_TEST_RELEASE_URL in
            http://127.0.0.1:*)
                base=$VIGIL_TEST_RELEASE_URL/packs
                curlopts=(-q --proto =http --proto-redir =http --noproxy '*' --max-time 60)
                ;;
            *)
                _vigil_pack_die 'VIGIL_TEST_RELEASE_URL must be http://127.0.0.1:<port>'
                return 1
                ;;
        esac
    fi
    command -v curl > /dev/null 2>&1 || { _vigil_pack_die 'curl not found'; return 1; }
    command -v openssl > /dev/null 2>&1 || { _vigil_pack_die 'openssl not found: a pack cannot be verified; nothing was changed'; return 1; }
    key=$app/release-key.pem
    [ -n "${VIGIL_TEST_RELEASE_URL-}" ] && [ -n "${VIGIL_TEST_RELEASE_KEY-}" ] && key=$VIGIL_TEST_RELEASE_KEY
    [ -f "$key" ] || { _vigil_pack_die 'no release key here: a pack cannot be verified; nothing was changed'; return 1; }
    tag=$(curl "${curlopts[@]}" -fsSLI -o /dev/null -w '%{url_effective}' "$base/releases/latest") ||
        { _vigil_pack_die 'cannot reach GitHub to find the latest packs'; return 1; }
    want=${tag##*/v}
    case $want in
        '' | */*)
            _vigil_pack_die "cannot tell the latest packs from $tag"
            return 1
            ;;
    esac
    _vp_work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-pack.XXXXXX") || { _vigil_pack_die 'cannot make a temporary folder'; return 1; }
    file=vigil-packs-$want.tar.gz
    for f in "$file" SHA256SUMS SHA256SUMS.sig; do
        if ! curl "${curlopts[@]}" -fsSL -o "$_vp_work/$f" "$base/releases/download/v$want/$f" 2> /dev/null; then
            _vigil_pack_die "cannot download the packs $want"
            return 1
        fi
    done
    if ! openssl dgst -sha256 -verify "$key" -signature "$_vp_work/SHA256SUMS.sig" "$_vp_work/SHA256SUMS" > /dev/null 2>&1; then
        _vigil_pack_die "the packs $want are not signed by the Vigil release key; nothing was changed"
        return 1
    fi
    sum=$(awk -v f="$file" '$2 == f || $2 == "*" f { print $1 }' "$_vp_work/SHA256SUMS")
    got=$(_vigil_self_sha "$_vp_work/$file")
    if [ -z "$sum" ] || [ "$got" != "$sum" ]; then
        _vigil_pack_die "the packs $want do not match their SHA256SUMS; nothing was changed"
        return 1
    fi
    mkdir "$_vp_work/x" && tar --no-same-owner -xzf "$_vp_work/$file" -C "$_vp_work/x" 2> /dev/null ||
        { _vigil_pack_die "cannot unpack the packs $want"; return 1; }
    _vp_src=$_vp_work/x/vigil-packs-$want
    [ -d "$_vp_src" ] || { _vigil_pack_die "the packs $want hold no vigil-packs-$want folder"; return 1; }
    _vp_want=$want
}

# What may stop an edit of the configuration, before anything is fetched.
_vigil_pack_writable() {
    local root=$1 cfg=$1/config/vigil.config
    vigil_config_parse "$cfg" || { _vigil_pack_die "$cfg has errors: fix them first (vigil precheck)"; return 1; }
    _vigil_wk_get vigil config_source ''
    if [ -n "$_vw_value" ]; then
        _vigil_pack_die "the configuration comes from [source.$_vw_value]: add the pack's jobs there"
        return 1
    fi
    if [ ! -w "$cfg" ] || ! { [ -w "$root/packs" ] || { [ ! -e "$root/packs" ] && [ -w "$root" ]; }; }; then
        _vigil_pack_die "$root is not writable: run this as the account that installed Vigil (sudo for a system install)"
        return 1
    fi
}

# Whether the configuration now in place is good for pack $2, which is judged
# by its own jobs, so a problem that was already there stops nothing. The
# reason is in _vp_why.
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

# The configuration with pack $2's block changed, on standard output: jobs not
# in _vp_jobs are taken out, and those missing added. With $3 = remove, the
# block goes. Sections the operator edited stay as they are.
_vigil_pack_rewrite() {
    local cfg=$1 name=$2 how=${3-} start end line bare in=0 keep=1 job seen=' ' j var
    start=$(_vigil_pack_start "$name")
    end=$(_vigil_pack_end "$name")
    while IFS= read -r line || [ -n "$line" ]; do
        bare=${line%$'\r'}
        if [ "$in" -eq 0 ]; then
            if [ "$bare" = "$start" ]; then
                in=1
                keep=1
                [ "$how" = remove ] || printf '%s\n' "$line"
            else
                printf '%s\n' "$line"
            fi
            continue
        fi
        if [ "$bare" = "$end" ]; then
            in=0
            if [ "$how" != remove ]; then
                for j in $_vp_jobs; do
                    case $seen in
                        *" $j "*) ;;
                        *)
                            var=_vp_section_$j
                            printf '\n%s' "${!var}"
                            ;;
                    esac
                done
                printf '%s\n' "$line"
            fi
            continue
        fi
        [ "$how" != remove ] || continue
        case $bare in
            "[job.${name}_"*)
                job=${bare#\[job."$name"_}
                job=${job%%]*}
                keep=0
                case " $_vp_jobs " in
                    *" $job "*)
                        keep=1
                        seen="$seen$job "
                        ;;
                esac
                ;;
        esac
        [ "$keep" -eq 0 ] || printf '%s\n' "$line"
    done < "$cfg"
}

# Puts pack $3 from $4 in place and changes the configuration to $5; goes back
# when the result is not valid.
_vigil_pack_commit() {
    local root=$1 work=$2 name=$3 src=$4 new=$5 cfg=$1/config/vigil.config dir=$1/packs/$3 had=0
    mkdir -p "$root/packs" || { _vigil_pack_die "cannot write to $root/packs"; return 1; }
    rm -rf "$dir.new" "$dir.old"
    cp -R "$src" "$dir.new" || { rm -rf "$dir.new"; _vigil_pack_die "cannot write to $root/packs; nothing was changed"; return 1; }
    chmod -R a+rX "$dir.new"
    cp "$cfg" "$work/config.before" || { rm -rf "$dir.new"; return 1; }
    if [ -d "$dir" ]; then
        mv "$dir" "$dir.old" || { rm -rf "$dir.new"; return 1; }
        had=1
    fi
    mv "$dir.new" "$dir"
    # Into the same file: its owner and mode stay.
    cat "$new" > "$cfg"
    if ! _vigil_pack_valid "$root" "$name"; then
        cat "$work/config.before" > "$cfg"
        rm -rf "$dir"
        [ "$had" -eq 0 ] || mv "$dir.old" "$dir"
        _vigil_pack_die "pack $name would not be valid here: $_vp_why; nothing was changed"
        return 1
    fi
    rm -rf "$dir.old"
}

vigil_pack_list() {
    local root=$1 d name n=0
    for d in "$root"/packs/*/; do
        [ -f "$d/pack.config" ] || continue
        name=${d%/}
        name=${name##*/}
        _vigil_pack_read "$d" "$name" || continue
        printf '%-12s %-10s %s\n' "$name" "$_vp_version" "$_vp_about"
        n=$((n + 1))
    done
    [ "$n" -gt 0 ] || printf 'no packs added: vigil pack add base\n'
    return 0
}

vigil_pack_add() {
    local root=$1 app=$2 name=$3 cfg=$1/config/vigil.config rc=0
    case $name in
        '' | *[!a-z0-9_]*) _vigil_pack_die "not a pack name: $name"; return 1 ;;
    esac
    [ -f "$cfg" ] || { _vigil_pack_die "no configuration here: run vigil init first"; return 1; }
    if [ -d "$root/packs/$name" ]; then
        _vigil_pack_die "pack $name is already added: vigil pack update"
        return 1
    fi
    _vigil_pack_writable "$root" || return 1
    _vp_work=''
    _vigil_pack_fetch "$app" || { [ -z "$_vp_work" ] || rm -rf "$_vp_work"; return 1; }
    _vigil_pack_install "$root" "$app" "$name" add
    rc=$?
    rm -rf "$_vp_work"
    return "$rc"
}

# Adds or updates pack $3 from the verified release.
_vigil_pack_install() {
    local root=$1 app=$2 name=$3 how=$4 cfg=$1/config/vigil.config src new j var
    src=$_vp_src/$name
    if ! _vigil_pack_read "$src" "$name"; then
        _vigil_pack_die "no pack called $name in the packs $_vp_want"
        return 1
    fi
    if [ -f "$app/VERSION" ] && [ -n "$_vp_vigil" ] && _vigil_self_newer "$_vp_vigil" "$(cat "$app/VERSION")"; then
        _vigil_pack_die "pack $name needs Vigil $_vp_vigil or later: vigil self update"
        return 1
    fi
    new=$_vp_work/config.new
    if [ "$how" = add ]; then
        {
            cat "$cfg"
            printf '\n'
            _vigil_pack_start "$name"
            for j in $_vp_jobs; do
                var=_vp_section_$j
                printf '%s\n' "${!var}"
            done
            _vigil_pack_end "$name"
        } > "$new"
    else
        _vigil_pack_rewrite "$cfg" "$name" > "$new"
    fi
    _vigil_pack_commit "$root" "$_vp_work" "$name" "$src" "$new" || return 1
    printf 'pack %s %s: jobs' "$name" "$_vp_version"
    for j in $_vp_jobs; do printf ' %s_%s' "$name" "$j"; done
    printf '\n'
}

vigil_pack_update() {
    local root=$1 app=$2 check=$3 d name was rc=0 n=0
    [ -d "$root/packs" ] || { printf 'no packs added: vigil pack add base\n'; return 0; }
    for d in "$root"/packs/*/; do [ -f "$d/pack.config" ] && n=$((n + 1)); done
    [ "$n" -gt 0 ] || { printf 'no packs added: vigil pack add base\n'; return 0; }
    if [ "$check" = 0 ]; then _vigil_pack_writable "$root" || return 1; fi
    _vp_work=''
    _vigil_pack_fetch "$app" || { [ -z "$_vp_work" ] || rm -rf "$_vp_work"; return 1; }
    for d in "$root"/packs/*/; do
        [ -f "$d/pack.config" ] || continue
        name=${d%/}
        name=${name##*/}
        _vigil_pack_read "$d" "$name" || continue
        was=$_vp_version
        if ! _vigil_pack_read "$_vp_src/$name" "$name"; then
            printf 'pack %s is no longer in the packs %s: left as it is\n' "$name" "$_vp_want"
        elif [ "$_vp_version" = "$was" ]; then
            printf 'pack %s %s is added: nothing to do\n' "$name" "$was"
        elif [ "$check" = 1 ]; then
            printf 'pack %s %s is added; %s is available: vigil pack update\n' "$name" "$was" "$_vp_version"
        else
            _vigil_pack_install "$root" "$app" "$name" update || rc=1
        fi
    done
    rm -rf "$_vp_work"
    return "$rc"
}

vigil_pack_remove() {
    local root=$1 name=$2 cfg=$1/config/vigil.config dir=$1/packs/$2 work
    case $name in
        '' | *[!a-z0-9_]*) _vigil_pack_die "not a pack name: $name"; return 1 ;;
    esac
    [ -d "$dir" ] || { _vigil_pack_die "pack $name is not added"; return 1; }
    _vigil_pack_writable "$root" || return 1
    work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-pack.XXXXXX") || { _vigil_pack_die 'cannot make a temporary folder'; return 1; }
    _vp_jobs=''
    _vigil_pack_rewrite "$cfg" "$name" remove > "$work/config.new"
    cp "$cfg" "$work/config.before" && cat "$work/config.new" > "$cfg"
    if ! _vigil_pack_valid "$root" "$name"; then
        cat "$work/config.before" > "$cfg"
        rm -rf "$work"
        _vigil_pack_die "the configuration would not be valid without pack $name: $_vp_why; nothing was changed"
        return 1
    fi
    rm -rf "$dir" "$work"
    printf 'removed pack %s\n' "$name"
}
