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
# A pack is a set of scripts and jobs (SPECIFICATION.md 18.10), published in
# the pack repository: packs releases, signed. A machine holds only the packs
# installed on it, in packs/<name>/, this platform's scripts, Vigil's to
# replace. The configuration is the operator's: Vigil runs only what it
# names, so installing or updating changes scripts and never the
# configuration, and a new script stays off until it is enabled. Must behave
# exactly as Pack.ps1.
#
#   vigil_pack_list <root>
#     Each pack here and whether its jobs are on.
#   vigil_pack_available <root> <app dir>
#     The repository's packs not installed here.
#   vigil_pack_search <root> <app dir> [<word>...]
#   vigil_pack_info <root> <app dir> <name>
#     From the newest index; when the repository cannot be reached, the one
#     saved here (packs/.index), saying so.
#   vigil_pack_install <root> <app dir> <folder, or ''> <name[@version]>...
#     From the repository, or a folder vigil pack download wrote.
#   vigil_pack_remove <root> <name>...
#     Refused while a job runs one of its scripts.
#   vigil_pack_download <root> <app dir> <linux|macos|windows> <folder> <name[@version]>...
#   vigil_pack_enable <root> <pack, or pack_job>
#   vigil_pack_disable <root> <pack, or pack_job>
#     Change the configuration, or nothing when the result is not valid.
#   vigil_pack_update <root> <app dir> <check: 0|1>
#     Updates the packs installed here to the repository's newest, never
#     back a version.
#   vigil_pack_verify <root> <app dir> <folder, or ''> [<name>...]
#     Checks the packs installed here, or those named, file by file against
#     the release of the version installed. Changes nothing. install of the
#     version installed puts back what differs.
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
        Darwin) _vp_os=macos _vp_osname=macOS ;;
        *) _vp_os=linux _vp_osname=Linux ;;
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
# script here, in order, each with its section in _vp_section_<job>; their
# scripts end in .$3 (sh by default; ps1 for Windows, for vigil pack config).
# Returns 1 when it cannot be read.
_vigil_pack_read() {
    local dir=$1 name=$2 ext=${3:-sh} j=0 sec job text i end
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
                if [ -f "$dir/$job.$ext" ]; then
                    text="[job.${name}_$job]"$'\n'"file = packs/$name/$job.$ext"$'\n'
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

# The pack repository (18.10). Packs releases are tagged packs-<date>, apart
# from Vigil's. Each carries packs.index, every version of every pack with
# the archive of each platform and its SHA-256, signed with the release key
# (packs.index.sig): one signature check vouches for every archive.

# Where packs come from, into _vp_base and _vp_mirror: 0 GitHub, 1 a
# release_url, 2 a release_path, 3 folder $3 (--from), which holds what
# vigil pack download wrote. Also the key that verifies them, in _vp_key.
_vigil_pack_source() {
    local root=$1 app=$2 from=$3
    command -v openssl > /dev/null 2>&1 || { _vigil_pack_die 'openssl not found: packs cannot be verified; nothing was changed'; return 1; }
    _vp_key=$app/release-key.pem
    [ -n "${VIGIL_TEST_RELEASE_URL-}" ] && [ -n "${VIGIL_TEST_RELEASE_KEY-}" ] && _vp_key=$VIGIL_TEST_RELEASE_KEY
    [ -f "$_vp_key" ] || { _vigil_pack_die 'no release key here: packs cannot be verified; nothing was changed'; return 1; }
    if [ -n "$from" ]; then
        _vp_base=$(cd "$from" 2> /dev/null && pwd) || { _vigil_pack_die "cannot read the folder $from"; return 1; }
        _vp_mirror=3
        _vp_curl=()
        return 0
    fi
    vigil_config_version "$root"
    vigil_release_source || return 1
    _vp_base=$_vu_base _vp_mirror=$_vu_mirror
    _vp_curl=("${_vu_curl[@]}" --max-time 60)
    [ "$_vp_mirror" = 2 ] || command -v curl > /dev/null 2>&1 || { _vigil_pack_die 'curl not found'; return 1; }
}

# File $2 of packs release $1 into $3: from the release, or the folder.
_vigil_pack_file() {
    local rel=$1 f=$2 out=$3 why
    if [ "$_vp_mirror" = 3 ]; then
        [ -f "$_vp_base/$f" ] && cp "$_vp_base/$f" "$out" 2> /dev/null && return 0
        _vigil_pack_die "$f is not in $_vp_base"
        return 1
    fi
    if ! vigil_release_get "$_vp_base" "$_vp_mirror" "releases/download/$rel/$f" "$out" "${_vp_curl[@]}" 2> /dev/null; then
        why=$(_vigil_release_refused "releases/download/$rel/$f")
        _vigil_pack_die "cannot download $f of $rel${why:+: $why}"
        return 1
    fi
}

# The newest packs release, printed. From a release_url or a release_path,
# the one line of <base>/packs/latest/RELEASE. From GitHub, the first packs-
# tag in the API's list of releases: a packs release is never marked latest,
# so /releases/latest names Vigil's. Tests serve the list at
# <base>/api/releases/all.
_vigil_pack_latest() {
    local tag api
    case $_vp_mirror in
        2) tag=$(head -n 1 "$_vp_base/packs/latest/RELEASE" 2> /dev/null | tr -d '[:space:]') ;;
        1) tag=$(_vigil_release_curl "${_vp_curl[@]}" -fsSL "$_vp_base/packs/latest/RELEASE" 2> /dev/null | head -n 1 | tr -d '[:space:]') ;;
        *)
            case $_vp_base in
                https://github.com/*) api="https://api.github.com/repos/${_vp_base#https://github.com/}/releases?per_page=100" ;;
                *) api=$_vp_base/api/releases/all ;;
            esac
            tag=$(curl "${_vp_curl[@]}" -fsSL -H 'Accept: application/vnd.github+json' "$api" 2> /dev/null |
                grep -o '"tag_name": *"packs-[^"/]*"' | sed -n '1s/.*"\(packs-[^"]*\)"$/\1/p')
            ;;
    esac
    case $tag in packs-[0-9]*) ;; *) return 1 ;; esac
    case $tag in *[!0-9A-Za-z.-]*) return 1 ;; esac
    printf '%s\n' "$tag"
}

# Whether index $1 is signed by the key here ($1.sig its signature).
_vigil_pack_signed() {
    openssl dgst -sha256 -verify "$_vp_key" -signature "$1.sig" "$1" > /dev/null 2>&1
}

# The format of index $1, printed: this Vigil reads 1.
_vigil_pack_format() {
    awk -F '\t' 'NR == 1 && $1 == "format" { print $2 } { exit }' "$1"
}

# The index of the newest packs release, or of the folder, verified, into
# _vp_index (in _vp_work). One fetched from a release is kept as
# packs/.index, when packs/ is writable, for search, info and list
# --available when the repository cannot be reached.
_vigil_pack_fetch_index() {
    local root=$1 rel='' from fmt
    if [ "$_vp_mirror" != 3 ]; then
        if ! rel=$(_vigil_pack_latest); then
            case $_vp_mirror in
                0) _vigil_pack_die "cannot find the latest packs release on $_vu_from: no network, or its API refused (it allows 60 requests an hour)" ;;
                2) _vigil_pack_die "cannot read packs/latest/RELEASE from $_vu_from (as $(id -un 2> /dev/null || echo this account)): is it there, and readable by this account?" ;;
                *)
                    from=$(_vigil_release_refused packs/latest/RELEASE)
                    _vigil_pack_die "cannot read packs/latest/RELEASE from $_vu_from${from:+: $from}"
                    ;;
            esac
            return 1
        fi
        # The newest release's index is the one saved here: no need to
        # download it again (backlog 65). Checked as one downloaded is; a
        # published release does not change.
        if [ -f "$root/packs/.index" ] && [ "$(_vigil_pack_release "$root/packs/.index")" = "$rel" ] &&
            _vigil_pack_signed "$root/packs/.index" && [ "$(_vigil_pack_format "$root/packs/.index")" = 1 ] &&
            cp "$root/packs/.index" "$_vp_work/packs.index" 2> /dev/null && cp "$root/packs/.index.sig" "$_vp_work/packs.index.sig" 2> /dev/null; then
            _vp_index=$_vp_work/packs.index
            return 0
        fi
    fi
    _vigil_pack_file "$rel" packs.index "$_vp_work/packs.index" || return 1
    _vigil_pack_file "$rel" packs.index.sig "$_vp_work/packs.index.sig" || return 1
    if ! _vigil_pack_signed "$_vp_work/packs.index"; then
        _vigil_pack_die "the pack index of ${rel:-$_vp_base} is not signed by the Vigil release key; nothing was changed"
        return 1
    fi
    fmt=$(_vigil_pack_format "$_vp_work/packs.index")
    [ "$fmt" = 1 ] || { _vigil_pack_die "the pack index is of a format this Vigil cannot read: vigil self update"; return 1; }
    _vp_index=$_vp_work/packs.index
    if [ "$_vp_mirror" != 3 ] && [ -d "$root/packs" ] && [ -w "$root/packs" ]; then
        cp "$_vp_index" "$root/packs/.index.new" 2> /dev/null && cp "$_vp_index.sig" "$root/packs/.index.sig.new" 2> /dev/null &&
            chmod a+r "$root/packs/.index.new" "$root/packs/.index.sig.new" &&
            mv -f "$root/packs/.index.sig.new" "$root/packs/.index.sig" && mv -f "$root/packs/.index.new" "$root/packs/.index"
        rm -f "$root/packs/.index.new" "$root/packs/.index.sig.new"
    fi
    return 0
}

# The release index $1 is of, printed.
_vigil_pack_release() {
    awk -F '\t' '$1 == "release" { print $2; exit }' "$1"
}

# Sets up for a command that reads the repository: the source, a temporary
# folder (_vp_work, which the caller removes) and the index from the newest
# release. With $4 = saved, when the repository cannot give it, the one
# packs/.index holds, when it is there and signed, saying so: search, info
# and list --available still answer offline, and never from an old index
# when a new one can be had.
_vigil_pack_begin() {
    local root=$1 app=$2 from=$3 how=${4-} saved=$1/packs/.index
    _vp_app=$app
    _vigil_pack_source "$root" "$app" "$from" || return 1
    _vp_work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-pack.XXXXXX") || { _vigil_pack_die 'cannot make a temporary folder'; return 1; }
    [ "$how" = saved ] || { _vigil_pack_fetch_index "$root"; return; }
    _vigil_pack_fetch_index "$root" 2> "$_vp_work/why" && return 0
    if [ -f "$saved" ] && _vigil_pack_signed "$saved" && [ "$(_vigil_pack_format "$saved")" = 1 ]; then
        _vp_index=$saved
        printf '%s; showing the index saved here, of %s\n' "$(sed -n 1p "$_vp_work/why")" "$(_vigil_pack_release "$saved")" >&2
        return 0
    fi
    cat "$_vp_work/why" >&2
    return 1
}

# Runs command $1 with the rest as its arguments, and removes _vp_work after.
_vigil_pack_run() {
    local rc
    _vp_work=''
    "$@"
    rc=$?
    [ -z "$_vp_work" ] || rm -rf "$_vp_work"
    _vp_work=''
    return "$rc"
}

# The version of pack $1 to take from the index: $2 when given, else the
# newest that Vigil $4 runs (any, when $4 is empty), with an archive for
# platform $3, and from a folder, its archive there. Into _vp_pick (empty
# when there is none, with the reason in _vp_why), _vp_pick_rel,
# _vp_pick_file and _vp_pick_sha; a newer version Vigil $4 cannot run in
# _vp_newer, with the Vigil it needs in _vp_newer_vigil.
_vigil_pack_pick() {
    local name=$1 want=$2 os=$3 mine=$4 v old rel file sha osname
    _vp_pick='' _vp_pick_rel='' _vp_pick_file='' _vp_pick_sha='' _vp_newer='' _vp_newer_vigil=''
    case $os in linux) osname=Linux ;; macos) osname=macOS ;; *) osname=Windows ;; esac
    _vp_why="no pack called $name: vigil pack search"
    [ -z "$want" ] || ! awk -F '\t' -v n="$name" '$1 == "pack" && $2 == n { f = 1 } END { exit !f }' "$_vp_index" ||
        _vp_why="pack $name has no version $want: vigil pack info $name"
    while IFS='	' read -r v old rel file sha; do
        [ -n "$v" ] || continue
        [ -z "$want" ] || [ "$v" = "$want" ] || continue
        if [ "$file" = - ]; then
            _vp_why="pack $name ${want:+$want }has no scripts for $osname"
            continue
        fi
        if [ "$_vp_mirror" = 3 ] && [ ! -f "$_vp_base/$file" ]; then
            _vp_why="$file is not in $_vp_base: vigil pack download $name${want:+@$want} there"
            continue
        fi
        if [ -n "$mine" ] && _vigil_self_newer "$old" "$mine"; then
            if [ -z "$_vp_newer" ] || _vigil_self_newer "$v" "$_vp_newer"; then
                _vp_newer=$v _vp_newer_vigil=$old
            fi
            _vp_why="pack $name $_vp_newer needs Vigil $_vp_newer_vigil or later: vigil self update"
            continue
        fi
        if [ -z "$_vp_pick" ] || _vigil_self_newer "$v" "$_vp_pick"; then
            _vp_pick=$v _vp_pick_rel=$rel _vp_pick_file=$file _vp_pick_sha=$sha
        fi
    done << EOF
$(awk -F '\t' -v n="$name" -v o="$os" '
    $1 == "pack" && $2 == n { old[$3] = $4; rel[$3] = $5; ord[++k] = $3 }
    $1 == "file" && $2 == n && $4 == o { f[$3] = $5; s[$3] = $6 }
    END {
        for (i = 1; i <= k; i++) {
            v = ord[i]
            printf "%s\t%s\t%s\t%s\t%s\n", v, old[v], rel[v], (v in f) ? f[v] : "-", (v in s) ? s[v] : "-"
        }
    }' "$_vp_index")
EOF
    [ -n "$_vp_pick" ]
}

# This Vigil's version, for _vigil_pack_pick.
_vigil_pack_mine() {
    _vp_mine=''
    [ -f "$_vp_app/VERSION" ] && read -r _vp_mine < "$_vp_app/VERSION"
    _vp_mine=${_vp_mine%$'\r'}
}

# The picked archive of pack $1, downloaded, checked against the index and
# unpacked: _vp_src is the pack's folder.
_vigil_pack_unpack() {
    local name=$1 f=$_vp_pick_file
    _vigil_pack_file "$_vp_pick_rel" "$f" "$_vp_work/$f" || return 1
    if [ "$(_vigil_self_sha "$_vp_work/$f")" != "$_vp_pick_sha" ]; then
        _vigil_pack_die "$f does not match the pack index; nothing was changed"
        return 1
    fi
    rm -rf "$_vp_work/x"
    mkdir "$_vp_work/x" || { _vigil_pack_die "cannot unpack $f"; return 1; }
    case $f in
        *.zip)
            # A Windows archive, read here only by vigil pack config --os windows.
            if command -v unzip > /dev/null 2>&1; then
                unzip -q -o "$_vp_work/$f" -d "$_vp_work/x" > /dev/null 2>&1 || { _vigil_pack_die "cannot unpack $f"; return 1; }
            elif tar --version 2> /dev/null | grep -q bsdtar; then
                tar -xf "$_vp_work/$f" -C "$_vp_work/x" 2> /dev/null || { _vigil_pack_die "cannot unpack $f"; return 1; }
            else
                _vigil_pack_die "unzip not found: needed to read $f, the Windows archive"
                return 1
            fi
            ;;
        *) tar --no-same-owner -xzf "$_vp_work/$f" -C "$_vp_work/x" 2> /dev/null || { _vigil_pack_die "cannot unpack $f"; return 1; } ;;
    esac
    _vp_src=$_vp_work/x/$name
    [ -f "$_vp_src/pack.config" ] || { _vigil_pack_die "$f holds no pack $name"; return 1; }
}

# Pack $2's folder here, $3, against its release's, $4, byte for byte: into
# _vp_count the release's files, and the names (space-separated) of those
# that differ here (_vp_changed), are not here (_vp_missing), and those here
# the release does not have (_vp_added). A script the release does not have
# that a job of configuration $1 runs, kept by vigil pack update when the
# pack dropped it, is not added: it is in _vp_kept, as <file>:<job>.
_vigil_pack_compare() {
    local cfg=$1 name=$2 here=$3 rel=$4 f b j i=0 n=0 runs=' '
    # Files in byte order, as Pack.ps1 lists them.
    local LC_ALL=C
    _vp_count=0 _vp_changed='' _vp_missing='' _vp_added='' _vp_kept=''
    for f in "$rel"/* "$rel"/.[!.]*; do
        [ -e "$f" ] || continue
        b=${f##*/}
        _vp_count=$((_vp_count + 1))
        if [ ! -f "$here/$b" ]; then
            _vp_missing="$_vp_missing $b"
        elif ! cmp -s "$f" "$here/$b"; then
            _vp_changed="$_vp_changed $b"
        fi
    done
    if [ -f "$cfg" ] && vigil_config_parse "$cfg" 2> /dev/null; then
        n=${#VIGIL_CFG_KEY[@]}
    fi
    while [ "$i" -lt "$n" ]; do
        case ${VIGIL_CFG_SECTION[$i]}:${VIGIL_CFG_KEY[$i]}:${VIGIL_CFG_VALUE[$i]} in
            job.*:file:packs/"$name"/*) runs="$runs${VIGIL_CFG_VALUE[$i]#packs/"$name"/}:${VIGIL_CFG_SECTION[$i]#job.} " ;;
        esac
        i=$((i + 1))
    done
    for f in "$here"/* "$here"/.[!.]*; do
        [ -e "$f" ] || continue
        b=${f##*/}
        [ ! -e "$rel/$b" ] || continue
        case $runs in
            *" $b:"*)
                j=${runs#* "$b":}
                _vp_kept="$_vp_kept $b:${j%% *}"
                ;;
            *) _vp_added="$_vp_added $b" ;;
        esac
    done
}


# Whether this host's configuration comes from a source (6.8): its source in
# _vp_csrc, the file in it in _vp_cfile. Parses the configuration.
_vigil_pack_pointer() {
    local cfg=$1/config/vigil.config
    _vp_csrc='' _vp_cfile=''
    [ -r "$cfg" ] && vigil_config_parse "$cfg" 2> /dev/null || return 1
    _vigil_wk_get vigil config_source ''
    _vp_csrc=$_vw_value
    _vigil_wk_get vigil config_file ''
    _vp_cfile=$_vw_value
    [ -n "$_vp_csrc" ]
}

# What to do instead, on a host whose configuration comes from a source: the
# operator changes it there (backlog 67). $1 is the pack, $2 enable, disable
# or install.
_vigil_pack_elsewhere() {
    printf "this host's configuration comes from [source.%s] (%s): Vigil does not edit it.\n" "$_vp_csrc" "$_vp_cfile"
    case $2 in
        disable) printf 'To turn pack %s off, take its jobs out of it there.\n' "$1" ;;
        *) printf 'To turn pack %s on, add its jobs there: vigil pack config %s prints them, ready to paste.\n' "$1" "$1" ;;
    esac
}

# What may stop an edit of the configuration for pack $2, which $3 (enable or
# disable) is about to make.
_vigil_pack_writable() {
    local root=$1 cfg=$1/config/vigil.config
    local denied
    if denied=$(vigil_denied "$cfg"); then _vigil_pack_die "$(vigil_denied_message "$denied")"; return 1; fi
    [ -f "$cfg" ] || { _vigil_pack_die 'no configuration here: run vigil init first'; return 1; }
    vigil_config_parse "$cfg" || { _vigil_pack_die "$cfg has errors: fix them first (vigil precheck)"; return 1; }
    if _vigil_pack_pointer "$root"; then
        _vigil_pack_die "$(_vigil_pack_elsewhere "${2-}" "${3-enable}")"
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
    local cfg=${3:-$1/config/vigil.config} name=$2 i=0
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

# Replaces the configuration with $3, once $3 is valid. Replaced, never
# written over: a crash or a full disk leaves the old file or the new one,
# never part of one, which could still be valid with fewer jobs (46). The copy
# is made from the old file, so its owner and mode stay.
_vigil_pack_apply() {
    local root=$1 name=$2 new=$3 cfg=$1/config/vigil.config tmp=$3.tmp
    if ! _vigil_pack_valid "$root" "$name" "$new"; then
        rm -f "$new"
        _vigil_pack_die "the configuration would not be valid: $_vp_why; nothing was changed"
        return 1
    fi
    if ! { cp -p "$cfg" "$tmp" && cat "$new" > "$tmp" && mv -f "$tmp" "$cfg"; }; then
        rm -f "$new" "$tmp"
        _vigil_pack_die "cannot save $cfg; nothing was changed"
        return 1
    fi
    rm -f "$new"
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
    local root=$1 d name j n=0 state denied
    # Whether a job is on cannot be told without the configuration, nor which
    # packs are here without the folder: say so, rather than "off".
    if denied=$(vigil_denied "$root/packs") || denied=$(vigil_denied "$root/config/vigil.config"); then
        _vigil_pack_die "$(vigil_denied_message "$denied")"
        return 1
    fi
    for d in "$root"/packs/*/; do
        [ -f "$d/pack.config" ] || continue
        name=${d%/}
        name=${name##*/}
        _vigil_pack_read "$d" "$name" || continue
        printf '%s %s: %s\n' "$name" "$_vp_version" "$_vp_about"
        # Its pack.config ships everywhere, its scripts only where they run (46).
        if [ -z "$_vp_jobs" ]; then
            _vigil_pack_os
            printf '  not available here: no scripts for %s\n' "$_vp_osname"
            n=$((n + 1))
            continue
        fi
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
    _vigil_pack_writable "$root" "$_vp_pack" enable || return 1
    _vigil_pack_read "$root/packs/$_vp_pack" "$_vp_pack" || { _vigil_pack_die "cannot read pack $_vp_pack"; return 1; }
    list=$_vp_jobs
    # Its pack.config ships everywhere, its scripts only where they run: nothing
    # here is nothing to turn on, not "already on" (46).
    if [ -z "$list" ]; then
        _vigil_pack_os
        _vigil_pack_die "pack $_vp_pack has no scripts for $_vp_osname"
        return 1
    fi
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
    _vigil_pack_writable "$root" "$_vp_pack" disable || return 1
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
    if [ -z "$was" ]; then
        # Its jobs are all new, and all off: the caller says so.
        printf 'installed pack %s %s\n' "$name" "$want_ver"
        return 0
    elif [ "$was" = "$want_ver" ]; then
        # The same version, put back as released (_vigil_pack_compare said
        # what differed).
        printf 'restored pack %s %s as released\n' "$name" "$want_ver"
        for b in $_vp_changed $_vp_missing; do printf '  put back  %s\n' "$b"; done
        for b in $_vp_added; do printf '  removed   %s\n' "$b"; done
        return 0
    elif _vigil_self_newer "$was" "$want_ver"; then
        printf 'pack %s went back from %s to %s\n' "$name" "$was" "$want_ver"
    else
        printf 'updated pack %s %s to %s\n' "$name" "$was" "$want_ver"
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

# What stops a change to packs/: what is here unreadable, or not writable.
_vigil_pack_changeable() {
    local root=$1
    if ! _vigil_pack_readable "$root"; then
        _vigil_pack_die "cannot read $root/packs from this account: run this as the account that installed Vigil (sudo for a system install)"
        return 1
    fi
    if ! { [ -w "$root/packs" ] || { [ ! -e "$root/packs" ] && [ -w "$root" ]; }; }; then
        _vigil_pack_die "$root/packs is not writable: run this as the account that installed Vigil (sudo for a system install)"
        return 1
    fi
}

# Whether $1 is name[@version], into _vp_name and _vp_at.
_vigil_pack_spec() {
    _vp_name=${1%%@*} _vp_at=''
    case $1 in *@*) _vp_at=${1#*@} ;; esac
    case $_vp_name in '' | *[!a-z0-9_]*) _vigil_pack_die "not a pack name: $1"; return 1 ;; esac
    case $1 in *@) _vigil_pack_die "no version after @: $1"; return 1 ;; esac
    case $_vp_at in *[!0-9A-Za-z.-]*) _vigil_pack_die "not a version: $1"; return 1 ;; esac
}

# Installs the picked version of pack $1, or says it is here already.
_vigil_pack_put() {
    local root=$1 name=$2 was='' j
    if _vigil_pack_read "$root/packs/$name" "$name"; then was=$_vp_version; fi
    _vigil_pack_unpack "$name" || return 1
    if [ "$was" = "$_vp_pick" ]; then
        # The version here: its files put back as released, where they differ.
        _vigil_pack_compare "$root/config/vigil.config" "$name" "$root/packs/$name" "$_vp_src"
        if [ -z "$_vp_changed$_vp_missing$_vp_added" ]; then
            printf 'pack %s %s is here: nothing to do\n' "$name" "$was"
            return 0
        fi
    fi
    mkdir -p "$root/packs" || { _vigil_pack_die "cannot write to $root/packs"; return 1; }
    _vigil_pack_replace "$root" "$_vp_app" "$name" "$_vp_src" "$was" || return 1
    [ -z "$was" ] || return 0
    # Installed, and off: what it has and what it needs, so it is never
    # turned on blind.
    _vigil_pack_read "$root/packs/$name" "$name"
    if _vigil_pack_pointer "$root"; then
        # The configuration comes from a source, so enable would refuse: its
        # jobs already there (committed before this install) are on; for the
        # rest, say loudly how to turn them on there (backlog 67).
        local on='' off='' act='' _vw_root=$root
        _vigil_wk_dir vigil state_dir state
        vigil_active_read "$_vw_dir" && act=$VIGIL_ACT_CONFIG
        for j in $_vp_jobs; do
            if [ -n "$act" ] && grep -q "^[[:space:]]*\[job\.${name}_$j\][[:space:]]*\$" "$act"; then
                on="$on ${name}_$j"
            else
                off="$off ${name}_$j"
            fi
        done
        [ -z "$on" ] || printf 'on, from [source.%s]:%s\n' "$_vp_csrc" "$on"
        if [ -n "$off" ]; then
            printf 'off until enabled:%s\n' "$off"
            _vigil_pack_elsewhere "$name" install
        fi
    else
        printf 'off until enabled:'
        for j in $_vp_jobs; do printf ' %s_%s' "$name" "$j"; done
        printf '\nTo turn them all on: vigil pack enable %s\n' "$name"
    fi
    vigil_config_parse "$root/config/vigil.config" 2> /dev/null
    _vigil_pack_needs "$root" "$name" ''
}

_vigil_pack_install() {
    local root=$1 app=$2 from=$3 s rc=0
    shift 3
    for s in "$@"; do _vigil_pack_spec "$s" || return 1; done
    _vigil_pack_changeable "$root" || return 1
    _vigil_pack_begin "$root" "$app" "$from" || return 1
    _vigil_pack_os
    _vigil_pack_mine
    for s in "$@"; do
        _vigil_pack_spec "$s"
        if ! _vigil_pack_pick "$_vp_name" "$_vp_at" "$_vp_os" "$_vp_mine"; then
            _vigil_pack_die "$_vp_why"
            rc=1
            continue
        fi
        _vigil_pack_put "$root" "$_vp_name" || rc=1
    done
    return "$rc"
}

# vigil pack config <name>[@<version>] [--os <os>] [--store <name>]: the block
# vigil pack enable would write, printed, for the configuration a source
# serves (backlog 67). This host's copy when it has the pack, --os is its own
# and no version is asked; else the newest version (or the one asked), its
# archive for that platform checked against the signed index: no pack
# installed, and no configuration needed. With --store, each secret: reference
# becomes store:<store>/<name>. Changes nothing.
_vigil_pack_config() {
    local root=$1 app=$2 spec=$3 os=$4 store=$5 dir ext osname from j var all='' left='' line
    _vigil_pack_spec "$spec" || return 1
    _vigil_pack_os
    [ -n "$os" ] || os=$_vp_os
    case $os in
        linux) osname=Linux ext=sh ;;
        macos) osname=macOS ext=sh ;;
        windows) osname=Windows ext=ps1 ;;
        *) _vigil_pack_die "--os takes linux, macos or windows, not $os"; return 1 ;;
    esac
    case $store in
        *[!A-Za-z0-9_-]*) _vigil_pack_die "not a secret store's name: $store"; return 1 ;;
    esac
    if [ -z "$_vp_at" ] && [ "$os" = "$_vp_os" ] && [ -f "$root/packs/$_vp_name/pack.config" ]; then
        dir=$root/packs/$_vp_name from='as installed here'
    else
        _vigil_pack_begin "$root" "$app" '' || return 1
        _vigil_pack_pick "$_vp_name" "$_vp_at" "$os" '' || { _vigil_pack_die "$_vp_why"; return 1; }
        _vigil_pack_unpack "$_vp_name" || return 1
        dir=$_vp_src from="from $_vp_pick_rel"
    fi
    _vigil_pack_read "$dir" "$_vp_name" "$ext" || { _vigil_pack_die "cannot read pack $_vp_name"; return 1; }
    [ -n "$_vp_jobs" ] || { _vigil_pack_die "pack $_vp_name has no scripts for $osname"; return 1; }
    # Its jobs with no script for that platform (vigil_config_parse kept them).
    j=0
    while [ "$j" -lt "${#VIGIL_CFG_SEC_NAME[@]}" ]; do
        case ${VIGIL_CFG_SEC_NAME[$j]} in
            job.*)
                all=${VIGIL_CFG_SEC_NAME[$j]#job.}
                case " $_vp_jobs " in *" $all "*) ;; *) left="$left ${_vp_name}_$all" ;; esac
                ;;
        esac
        j=$((j + 1))
    done
    printf '# pack %s %s for %s, %s.\n' "$_vp_name" "$_vp_version" "$osname" "$from"
    printf '# Its jobs, for a configuration that comes from a source: paste them\n'
    printf '# into it. Each env line holds the pack'"'"'s default: set it for your\n'
    printf '# hosts. It runs on Vigil %s or later.\n' "${_vp_vigil:-0.3.0}"
    while IFS= read -r line; do
        [ -n "$line" ] && printf '# needs %s\n' "$line"
    done << EOF
$_vp_needs
EOF
    [ -z "$left" ] || printf '# no %s script, so not here:%s\n' "$osname" "$left"
    printf '\n'
    _vigil_pack_start "$_vp_name"
    for j in $_vp_jobs; do
        var=_vp_section_$j
        printf '\n'
        if [ -n "$store" ]; then
            printf '%s' "${!var}" | sed "s#^\(secret = [^=]*=\)secret:#\1store:$store/#"
        else
            printf '%s' "${!var}"
        fi
    done
    _vigil_pack_end "$_vp_name"
}

_vigil_pack_update() {
    local root=$1 app=$2 check=$3 d name was rc=0 n=0 s
    local -a dirs=()
    shift 3
    if ! _vigil_pack_readable "$root"; then
        _vigil_pack_die "cannot read $root/packs from this account: run this as the account that installed Vigil (sudo for a system install)"
        return 1
    fi
    # The packs named, else every pack here. Each named must be installed,
    # and is checked before anything is fetched. A version is install's to
    # pick: update only ever moves a pack forward.
    for s in "$@"; do
        _vigil_pack_spec "$s" || return 1
        [ -z "$_vp_at" ] || { _vigil_pack_die "pack update takes the newest version; for another: vigil pack install $s"; return 1; }
        _vigil_pack_read "$root/packs/$_vp_name" "$_vp_name" || { _vigil_pack_die "pack $_vp_name is not installed: vigil pack install $_vp_name"; return 1; }
        dirs+=("$root/packs/$_vp_name/")
    done
    [ "${#dirs[@]}" -gt 0 ] || dirs=("$root"/packs/*/)
    [ "$check" = 1 ] || _vigil_pack_changeable "$root" || return 1
    _vigil_pack_begin "$root" "$app" '' || return 1
    _vigil_pack_os
    _vigil_pack_mine
    for d in "${dirs[@]}"; do
        [ -f "$d/pack.config" ] || continue
        d=${d%/}
        name=${d##*/}
        _vigil_pack_read "$d" "$name" || continue
        was=$_vp_version
        n=$((n + 1))
        if ! _vigil_pack_pick "$name" '' "$_vp_os" "$_vp_mine"; then
            if [ -n "$_vp_newer" ]; then
                printf 'pack %s %s is here; %s needs Vigil %s or later: vigil self update\n' "$name" "$was" "$_vp_newer" "$_vp_newer_vigil"
            else
                printf 'pack %s %s is here, and not in the repository for %s: kept as it is\n' "$name" "$was" "$_vp_osname"
            fi
            continue
        fi
        # Never back a version: one newer than the repository's stays.
        if ! _vigil_self_newer "$_vp_pick" "$was"; then
            printf 'pack %s %s is here: nothing to do\n' "$name" "$was"
        elif [ "$check" = 1 ]; then
            printf 'pack %s %s is here; %s is available: vigil pack update %s\n' "$name" "$was" "$_vp_pick" "$name"
        else
            _vigil_pack_put "$root" "$name" || rc=1
        fi
        [ -z "$_vp_newer" ] || printf '  %s %s needs Vigil %s or later: vigil self update\n' "$name" "$_vp_newer" "$_vp_newer_vigil"
    done
    [ "$n" -gt 0 ] || printf 'no packs here: vigil pack search, then vigil pack install <name>\n'
    return "$rc"
}

# The jobs of configuration $1 that run a script of pack $2, into _vp_users.
_vigil_pack_users() {
    local i=0 n=0
    _vp_users=''
    if [ -f "$1" ]; then
        vigil_config_parse "$1" 2> /dev/null
        n=${#VIGIL_CFG_KEY[@]}
    fi
    while [ "$i" -lt "$n" ]; do
        case ${VIGIL_CFG_SECTION[$i]}:${VIGIL_CFG_KEY[$i]}:${VIGIL_CFG_VALUE[$i]} in
            job.*:file:packs/"$2"/*) _vp_users="$_vp_users ${VIGIL_CFG_SECTION[$i]#job.}" ;;
        esac
        i=$((i + 1))
    done
}

_vigil_pack_remove() {
    local root=$1 off=$2 s cfg=$1/config/vigil.config denied i n jobs dir rc=0
    shift 2
    for s in "$@"; do
        _vigil_pack_spec "$s" || return 1
        [ -z "$_vp_at" ] || { _vigil_pack_die "a pack is removed whole, any version: $_vp_name"; return 1; }
    done
    if denied=$(vigil_denied "$cfg"); then _vigil_pack_die "$(vigil_denied_message "$denied")"; return 1; fi
    if [ -f "$cfg" ] && ! vigil_config_parse "$cfg" 2> /dev/null; then
        _vigil_pack_die "$cfg has errors: fix them first (vigil precheck)"
        return 1
    fi
    _vigil_pack_changeable "$root" || return 1
    for s in "$@"; do
        dir=$root/packs/$s
        if ! _vigil_pack_read "$dir" "$s"; then
            _vigil_pack_die "pack $s is not installed: vigil pack list"
            rc=1
            continue
        fi
        # A job running one of its scripts would fail at its next run. With
        # --disable, the pack's own jobs are taken out first, as vigil pack
        # disable takes them. A job of the configuration's own that runs one
        # of its scripts keeps the pack: that is found first, and then
        # nothing is changed, not even the pack's jobs turned off.
        _vigil_pack_users "$cfg" "$s"
        jobs=$_vp_users
        if [ "$off" = 1 ] && [ -n "$jobs" ]; then
            local own='' theirs='' pj=' ' j
            for j in $_vp_jobs; do pj="$pj${s}_$j "; done
            for j in $jobs; do
                case $pj in
                    *" $j "*) theirs="$theirs $j" ;;
                    *) own="$own $j" ;;
                esac
            done
            if [ -n "$own" ]; then
                _vigil_pack_die "pack $s is still used by jobs of your own:$own. Change them or take them out first"
                rc=1
                continue
            fi
            vigil_pack_disable "$root" "$s" || { rc=1; continue; }
            _vigil_pack_users "$cfg" "$s"
            jobs=$_vp_users
            _vigil_pack_read "$dir" "$s"
        fi
        if [ -n "$jobs" ]; then
            _vigil_pack_die "pack $s is in use by:$jobs. Turn them off first: vigil pack disable $s, or vigil pack remove --disable $s"
            rc=1
            continue
        fi
        rm -rf "$dir.old"
        if ! mv "$dir" "$dir.old"; then
            _vigil_pack_die "cannot remove $dir"
            rc=1
            continue
        fi
        rm -rf "$dir.old"
        printf 'removed pack %s %s\n' "$s" "$_vp_version"
    done
    return "$rc"
}

# The width of the terminal standard output is, into _vp_cols, or 0 when it
# is not one: rows piped or written to a file stay whole.
_vigil_pack_cols() {
    _vp_cols=0
    [ -t 1 ] || return 0
    # The terminal's own size first: tput, its output a pipe here, gives
    # its terminfo default (80) on macOS.
    _vp_cols=$(stty size < /dev/tty 2> /dev/null | cut -d ' ' -f 2)
    case $_vp_cols in '' | *[!0-9]* | 0) _vp_cols=${COLUMNS-} ;; esac
    case $_vp_cols in '' | *[!0-9]* | 0) _vp_cols=$(tput cols 2> /dev/null) ;; esac
    case $_vp_cols in '' | *[!0-9]* | 0) _vp_cols=80 ;; esac
}

# Rows of tab-separated fields on stdin, the first the header, as a table:
# each column as wide as its widest field, a rule under each header, and
# with $1 the terminal's width (0: none), the last column cut to fit, with
# "...", so each row stays one line.
_vigil_pack_table() {
    awk -F '\t' -v cols="$1" '
        function show(r,   i, x, line) {
            line = ""
            for (i = 1; i <= k; i++) {
                x = c[r, i]
                if (i == k && length(x) > w[k]) x = substr(x, 1, w[k] - 3) "..."
                line = line (i > 1 ? " " : "") (i < k ? sprintf("%-" w[i] "s", x) : x)
            }
            sub(/ +$/, "", line)
            print line
        }
        {
            n = NR
            if (NR == 1) k = NF
            for (i = 1; i <= k; i++) { c[NR, i] = $i; if (length($i) > w[i]) w[i] = length($i) }
        }
        END {
            if (n == 0) exit
            if (cols > 0) {
                room = cols - 1
                for (i = 1; i < k; i++) room -= w[i] + 1
                if (room < 10) room = 10
                if (w[k] > room) w[k] = room
            }
            show(1)
            for (i = 1; i <= k; i++) { x = c[1, i]; gsub(/./, "-", x); c[0, i] = x }
            show(0)
            for (r = 2; r <= n; r++) show(r)
        }'
}

# The index's packs, as a table with the newest version of each: those
# whose name or description has every word of $3 (all, when there is none),
# or with $2 = available, those not installed.
_vigil_pack_show() {
    local root=$1 how=$2 words=$3 name v plats about here rows='' n=0 was
    _vigil_pack_os
    while IFS='	' read -r name v plats about; do
        [ -n "$name" ] || continue
        was=''
        if _vigil_pack_read "$root/packs/$name" "$name"; then was=$_vp_version; fi
        [ "$how" != available ] || [ -z "$was" ] || continue
        if [ -z "$was" ]; then
            case " $plats " in *" $_vp_os "*) here='' ;; *) here="not for $_vp_osname" ;; esac
        elif [ "$was" = "$v" ]; then
            here=installed
        else
            here="$was installed"
        fi
        rows="$rows$name	$v	$here	$about"$'\n'
        n=$((n + 1))
    done << EOF
$(awk -F '\t' -v w="$words" '
    function newer(a, b,   x, y, i) {
        split(a, x, /[.-]/); split(b, y, /[.-]/)
        for (i = 1; i <= 3; i++) { if (x[i] + 0 > y[i] + 0) return 1; if (x[i] + 0 < y[i] + 0) return 0 }
        return 0
    }
    $1 == "pack" && (!($2 in v) || newer($3, v[$2])) { v[$2] = $3; d[$2] = $7 }
    $1 == "file" { p[$2 SUBSEP $3] = p[$2 SUBSEP $3] " " $4 }
    END {
        k = split(tolower(w), ws, " ")
        for (n in v) {
            t = tolower(n " " d[n])
            for (i = 1; i <= k; i++) if (index(t, ws[i]) == 0) break
            if (i <= k) continue
            q = substr(p[n SUBSEP v[n]], 2)
            printf "%s\t%s\t%s\t%s\n", n, v[n], (q == "") ? "-" : q, d[n]
        }
    }' "$_vp_index" | LC_ALL=C sort)
EOF
    if [ "$n" -eq 0 ]; then
        if [ "$how" = available ]; then
            printf 'every pack is installed\n'
        else
            printf 'no pack matches: %s\n' "$words"
        fi
        return 0
    fi
    if [ "$how" = available ]; then
        printf 'Packs in %s not installed here:\n\n' "$(_vigil_pack_release "$_vp_index")"
    else
        printf 'Packs in %s:\n\n' "$(_vigil_pack_release "$_vp_index")"
    fi
    _vigil_pack_cols
    printf 'Name\tVersion\tHere\tAbout\n%s' "$rows" | _vigil_pack_table "$_vp_cols"
}

_vigil_pack_search() {
    local root=$1 app=$2
    shift 2
    _vigil_pack_begin "$root" "$app" '' saved || return 1
    _vigil_pack_show "$root" search "$*"
}

_vigil_pack_available() {
    _vigil_pack_begin "$1" "$2" '' saved || return 1
    _vigil_pack_show "$1" available ''
}

# One pack, from the index: what it is, whether it is here, what it needs
# (its newest version's info records), and every version, newest first.
_vigil_pack_info() {
    local root=$1 app=$2 name=$3 was='' newest here
    _vigil_pack_spec "$name" || return 1
    [ -z "$_vp_at" ] || { _vigil_pack_die "vigil pack info takes a name, without a version: $_vp_name"; return 1; }
    _vigil_pack_begin "$root" "$app" '' saved || return 1
    newest=$(awk -F '\t' -v n="$name" '
        function newer(a, b,   x, y, i) {
            split(a, x, /[.-]/); split(b, y, /[.-]/)
            for (i = 1; i <= 3; i++) { if (x[i] + 0 > y[i] + 0) return 1; if (x[i] + 0 < y[i] + 0) return 0 }
            return 0
        }
        $1 == "pack" && $2 == n && (v == "" || newer($3, v)) { v = $3 }
        END { print v }' "$_vp_index")
    if [ -z "$newest" ]; then
        _vigil_pack_die "no pack called $name: vigil pack search"
        return 1
    fi
    _vigil_pack_os
    _vigil_pack_mine
    if _vigil_pack_read "$root/packs/$name" "$name"; then was=$_vp_version; fi
    _vigil_pack_pick "$name" '' "$_vp_os" "$_vp_mine" || :
    if [ -n "$was" ]; then
        if [ -n "$_vp_pick" ] && _vigil_self_newer "$_vp_pick" "$was"; then
            here="$was installed; $_vp_pick is available: vigil pack update $name"
        elif [ -n "$_vp_newer" ] && _vigil_self_newer "$_vp_newer" "$was"; then
            here="$was installed; $_vp_newer needs Vigil $_vp_newer_vigil or later: vigil self update"
        elif [ "$was" = "$newest" ]; then
            here="$was installed, the newest"
        else
            here="$was installed"
        fi
    elif [ -n "$_vp_pick" ]; then
        here="not installed: vigil pack install $name"
    elif [ -n "$_vp_newer" ]; then
        here="not installed; $_vp_newer needs Vigil $_vp_newer_vigil or later: vigil self update"
    else
        here="not for $_vp_osname"
    fi
    awk -F '\t' -v n="$name" -v v="$newest" -v here="$here" -v os="$_vp_os" '
        function pretty(o) { return o == "linux" ? "Linux" : o == "macos" ? "macOS" : "Windows" }
        # Items 1 to k of list, as "a", "a and b" or "a, b and c".
        function joined(list, k,   i, s) {
            s = list[1]
            for (i = 2; i <= k; i++) s = s (i == k ? " and " : ", ") list[i]
            return s
        }
        function lead(label) { return label == "" ? sprintf("%13s", "") : sprintf("%-10s : ", label) }
        # A field, its text wrapped at 78 columns under itself; a word is
        # never split.
        function field(label, text,   k, ws, i, line, pre) {
            pre = lead(label)
            k = split(text, ws, " ")
            line = ""
            for (i = 1; i <= k; i++) {
                if (line != "" && length(pre) + length(line) + 1 + length(ws[i]) > 78) {
                    print pre line
                    pre = lead("")
                    line = ws[i]
                } else line = (line == "" ? ws[i] : line " " ws[i])
            }
            print pre line
        }
        $1 == "pack" && $2 == n && $3 == v { about = $7 }
        $1 == "file" && $2 == n && $3 == v { has[$4] = 1 }
        $1 == "info" && $2 == n && $3 == v {
            info = 1
            if ($4 == "secret") sec[++ks] = $5
            else if ($4 == "needs") nd[++kn] = $5
            else if ($4 == "setting") st[++kt] = $5
            else one[$4] = $5
        }
        END {
            field("Name", n)
            field("About", about)
            field("Here", here)
            split("linux macos windows", all, " ")
            kp = 0
            for (i = 1; i <= 3; i++) if (all[i] in has) { ps[++kp] = pretty(all[i]); po[kp] = all[i] }
            if (kp == 0) field("Platforms", "none")
            else { s = ps[1]; for (i = 2; i <= kp; i++) s = s ", " ps[i]; field("Platforms", s) }
            if (one["works_with"] != "") field("Works with", one["works_with"])
            if (!info) exit
            # This platform s programs; or, with no scripts here, those of
            # the platforms it has.
            if (os in has) {
                x = one["programs_" os]
                field("Programs", x != "" ? x : "none on " pretty(os))
            } else if (kp > 0) {
                same = 1
                for (i = 2; i <= kp; i++) if (one["programs_" po[i]] != one["programs_" po[1]]) same = 0
                if (same) {
                    x = one["programs_" po[1]]
                    field("Programs", x == "" ? "none" : x " (on " joined(ps, kp) ")")
                } else {
                    s = ""
                    for (i = 1; i <= kp; i++) {
                        x = one["programs_" po[i]]
                        if (x != "") s = s (s == "" ? "" : ", ") x " (on " ps[i] ")"
                    }
                    field("Programs", s)
                }
            }
            if (ks == 0) field("Secrets", "none")
            else { s = sec[1]; for (i = 2; i <= ks; i++) s = s ", " sec[i]; field("Secrets", s) }
            # What it is, wrapped, then the command whole on a line of its
            # own, to copy.
            for (i = 1; i <= kn; i++) {
                p = index(nd[i], ": ")
                if (p > 0) {
                    field(i == 1 ? "Needs" : "", substr(nd[i], 1, p))
                    print lead("") substr(nd[i], p + 2)
                } else field(i == 1 ? "Needs" : "", nd[i])
            }
            if (kt > 0) {
                s = st[1]
                for (i = 2; i <= kt; i++) s = s " " st[i]
                field("Settings", s " (the env lines in vigil.config, once enabled)")
            }
            if (one["docs"] != "") print lead("Docs") one["docs"]
        }' "$_vp_index"
    printf '\n'
    awk -F '\t' -v n="$name" '
        function newer(a, b,   x, y, i) {
            split(a, x, /[.-]/); split(b, y, /[.-]/)
            for (i = 1; i <= 3; i++) { if (x[i] + 0 > y[i] + 0) return 1; if (x[i] + 0 < y[i] + 0) return 0 }
            return 0
        }
        function pretty(o) { return o == "linux" ? "Linux" : o == "macos" ? "macOS" : "Windows" }
        $1 == "pack" && $2 == n { o[$3] = $4; r[$3] = $5; vs[++k] = $3 }
        $1 == "file" && $2 == n { has[$3, $4] = 1 }
        END {
            for (i = 2; i <= k; i++) for (j = i; j > 1 && newer(vs[j], vs[j - 1]); j--) { t = vs[j]; vs[j] = vs[j - 1]; vs[j - 1] = t }
            split("linux macos windows", all, " ")
            print "Version\tPlatforms\tNeeds Vigil\tRelease"
            for (i = 1; i <= k; i++) {
                v = vs[i]
                p = ""
                for (j = 1; j <= 3; j++) if ((v, all[j]) in has) p = p (p == "" ? "" : ", ") pretty(all[j])
                printf "%s\t%s\t%s\t%s\n", v, (p == "") ? "none" : p, o[v], r[v]
            }
        }' "$_vp_index" | _vigil_pack_table 0
}

_vigil_pack_download() {
    local root=$1 app=$2 os=$3 to=$4 s osname got mine
    shift 4
    case $os in
        linux) osname=Linux ;;
        macos) osname=macOS ;;
        windows) osname=Windows ;;
        *) _vigil_pack_die "not a platform: $os (linux, macos or windows)"; return 1 ;;
    esac
    for s in "$@"; do _vigil_pack_spec "$s" || return 1; done
    mkdir -p "$to" 2> /dev/null && [ -w "$to" ] || { _vigil_pack_die "cannot write to $to"; return 1; }
    _vigil_pack_begin "$root" "$app" '' || return 1
    _vigil_pack_mine
    for s in "$@"; do
        _vigil_pack_spec "$s"
        # The version install would take here; one asked for, whatever
        # Vigil it needs, as the machine it is for may run another.
        mine=$_vp_mine
        [ -z "$_vp_at" ] || mine=''
        _vigil_pack_pick "$_vp_name" "$_vp_at" "$os" "$mine" || { _vigil_pack_die "$_vp_why"; return 1; }
        _vigil_pack_file "$_vp_pick_rel" "$_vp_pick_file" "$_vp_work/$_vp_pick_file" || return 1
        got=$(_vigil_self_sha "$_vp_work/$_vp_pick_file")
        [ "$got" = "$_vp_pick_sha" ] || { _vigil_pack_die "$_vp_pick_file does not match the pack index; nothing was written"; return 1; }
        cp "$_vp_work/$_vp_pick_file" "$to/" || { _vigil_pack_die "cannot write to $to"; return 1; }
        printf 'downloaded %s %s for %s: %s\n' "$_vp_name" "$_vp_pick" "$osname" "$_vp_pick_file"
    done
    cp "$_vp_index" "$to/packs.index" && cp "$_vp_index.sig" "$to/packs.index.sig" || { _vigil_pack_die "cannot write to $to"; return 1; }
    printf 'with the signed index. There: vigil pack install <name> --from <this folder>\n'
}

# Checks the packs installed here against the packs release each version
# came from, every file byte for byte, its archive checked against the
# signed index as install checks it. Reads only.
_vigil_pack_verify() {
    local root=$1 app=$2 from=$3 d name s b rc=0 n=0
    local -a dirs=()
    shift 3
    if ! _vigil_pack_readable "$root"; then
        _vigil_pack_die "cannot read $root/packs from this account: run this as the account that installed Vigil (sudo for a system install)"
        return 1
    fi
    for s in "$@"; do
        _vigil_pack_spec "$s" || return 1
        [ -z "$_vp_at" ] || { _vigil_pack_die "pack verify checks the version installed here: vigil pack verify $_vp_name"; return 1; }
        _vigil_pack_read "$root/packs/$_vp_name" "$_vp_name" || { _vigil_pack_die "pack $_vp_name is not installed: vigil pack list"; return 1; }
        dirs+=("$root/packs/$_vp_name/")
    done
    [ "${#dirs[@]}" -gt 0 ] || dirs=("$root"/packs/*/)
    _vigil_pack_begin "$root" "$app" "$from" || return 1
    _vigil_pack_os
    for d in "${dirs[@]}"; do
        [ -f "$d/pack.config" ] || continue
        d=${d%/}
        name=${d##*/}
        if ! _vigil_pack_read "$d" "$name"; then
            printf 'pack %s: cannot read its pack.config\n' "$name"
            rc=1
            continue
        fi
        n=$((n + 1))
        # A pack of your own, or a version no release has: nothing to check against.
        if ! awk -F '\t' -v n="$name" -v v="$_vp_version" '$1 == "pack" && $2 == n && $3 == v { f = 1 } END { exit !f }' "$_vp_index"; then
            printf 'pack %s %s: not in the repository, not checked\n' "$name" "$_vp_version"
            continue
        fi
        if ! _vigil_pack_pick "$name" "$_vp_version" "$_vp_os" ''; then
            printf 'pack %s %s: cannot check it: %s\n' "$name" "$_vp_version" "$_vp_why"
            rc=1
            continue
        fi
        # Why it cannot be had, or does not match the index, is on stderr.
        if ! _vigil_pack_unpack "$name"; then
            printf 'pack %s %s: cannot check it\n' "$name" "$_vp_pick"
            rc=1
            continue
        fi
        _vigil_pack_compare "$root/config/vigil.config" "$name" "$d" "$_vp_src"
        if [ -z "$_vp_changed$_vp_missing$_vp_added" ]; then
            printf 'pack %s %s: its %d files match %s\n' "$name" "$_vp_pick" "$_vp_count" "$_vp_pick_rel"
        else
            printf 'pack %s %s: differs from %s\n' "$name" "$_vp_pick" "$_vp_pick_rel"
            rc=1
        fi
        for b in $_vp_changed; do printf '  changed  %s\n' "$b"; done
        for b in $_vp_missing; do printf '  missing  %s\n' "$b"; done
        for b in $_vp_added; do printf '  added    %s\n' "$b"; done
        for b in $_vp_kept; do printf '  kept     %s: dropped from the pack, still run by %s\n' "${b%%:*}" "${b#*:}"; done
        [ -z "$_vp_changed$_vp_missing$_vp_added" ] || printf '  To put it back as released: vigil pack install %s@%s\n' "$name" "$_vp_pick"
    done
    [ "$n" -gt 0 ] || printf 'no packs here: vigil pack search, then vigil pack install <name>\n'
    return "$rc"
}

vigil_pack_verify() { _vigil_pack_run _vigil_pack_verify "$@"; }
vigil_pack_update() { _vigil_pack_run _vigil_pack_update "$@"; }
vigil_pack_install() { _vigil_pack_run _vigil_pack_install "$@"; }
vigil_pack_remove() { _vigil_pack_remove "$@"; }
vigil_pack_search() { _vigil_pack_run _vigil_pack_search "$@"; }
vigil_pack_available() { _vigil_pack_run _vigil_pack_available "$@"; }
vigil_pack_info() { _vigil_pack_run _vigil_pack_info "$@"; }
vigil_pack_download() { _vigil_pack_run _vigil_pack_download "$@"; }
vigil_pack_config() { _vigil_pack_run _vigil_pack_config "$@"; }
