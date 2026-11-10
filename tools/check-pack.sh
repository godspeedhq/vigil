#!/usr/bin/env bash
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
# check-pack.sh - checks packs against CONTRIBUTING.md, and says what to fix.
#
#   tools/check-pack.sh [--run] [<pack> ...]     every pack when none is named
#
# It reads pack.config with Vigil's own parser, and checks its keys, the names
# of the pack, its jobs and their metrics, that each job has a script and
# each script a job, the scripts' headers (the notice, every metric named, no
# TODO left), that they parse (bash -n; PowerShell's parser when there is a
# PowerShell), and that packs/README.md has a section for the pack.
#
# --run also runs the pack, on Linux and macOS (tools/Check-Pack.ps1 does the
# same for the Windows scripts): in a throwaway Vigil, vigil pack enable turns
# it on (which validates its jobs as Vigil sees them), each job with a script
# for this platform runs, and every metric it prints must be a number and
# listed in pack.config. A job whose secret a throwaway Vigil does not have is
# skipped, and says which; a job whose service this machine lacks reports it
# as it would anywhere. Its test against the real service is the one that
# counts.
#
# Exit code: 0 all passed, 1 any failed.

set -u

cd "$(dirname "$0")/.." || exit 1

run=0
if [ "${1-}" = --run ]; then
    run=1
    shift
fi
case ${1-} in -*)
    echo 'usage: tools/check-pack.sh [--run] [<pack> ...]' >&2
    exit 1
    ;;
esac

# shellcheck source=/dev/null
. app/lib/posix/config.sh

failed=0
before=0
pack=''
fail() {
    printf '  FAIL  %s: %s\n' "$pack" "$1"
    failed=$((failed + 1))
}

ps=''
if command -v pwsh > /dev/null 2>&1; then
    ps=pwsh
elif command -v powershell > /dev/null 2>&1; then
    ps=powershell
fi
native() {
    if command -v cygpath > /dev/null 2>&1; then cygpath -w "$@"; else printf '%s\n' "$@"; fi
}

semver='^[0-9]+\.[0-9]+\.[0-9]+$'
re_metric='^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$'
re_part='^[a-z][a-z0-9_]*$'
notice=(
    'Copyright (c) Bankole Ogundero and the Vigil contributors'
    'SPDX-License-Identifier: Apache-2.0'
    'WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND'
)

# The text of file $1 in _text, its first line in _first, and the number of
# the first line holding TODO in _todo (0 when none). Read in bash: on Windows
# a process is slow to start, and a pack has many files.
read_text() {
    local line n=0
    _text='' _first='' _todo=0
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        line=${line%$'\r'}
        [ "$n" -eq 1 ] && _first=${line#$'\357\273\277'}
        _text="$_text$line"$'\n'
        if [ "$_todo" -eq 0 ] && [[ $line == *TODO* ]]; then _todo=$n; fi
    done < "$1"
}

# Checks file $1, read by read_text: the notice and no TODO.
check_common() {
    local phrase
    for phrase in "${notice[@]}"; do
        [[ $_text == *"$phrase"* ]] || fail "$1: the header lacks \"$phrase\" (copy it from packs/base)"
    done
    [ "$_todo" -eq 0 ] || fail "$1: TODO left on line $_todo"
}

# Checks script $1, whose job lists metrics $2.
check_script() {
    local file=$1 m err
    read_text "$file"
    check_common "$file"
    for m in $2; do
        [[ $m =~ $re_part ]] || continue
        [[ $_text =~ (^|[^a-z0-9_])$m([^a-z0-9_]|$) ]] || fail "$file: metric $m (in pack.config) is not in its header"
    done
    case $file in
        *.sh)
            [ "$_first" = '#!/usr/bin/env bash' ] || fail "$file: the first line must be #!/usr/bin/env bash"
            err=$(bash -n "$file" 2>&1) || fail "$file: bash cannot parse it: $err"
            ;;
        *.ps1)
            [ "$_first" = '#Requires -Version 5.1' ] || fail "$file: the first line must be #Requires -Version 5.1"
            ps_files+=("$file")
            ;;
    esac
}

# Parses the .ps1 files gathered in ps_files with PowerShell's own parser, in
# one PowerShell: starting one takes a second or more.
parse_ps() {
    local line
    [ -n "$ps" ] && [ "${#ps_files[@]}" -gt 0 ] || return 0
    while IFS= read -r line; do
        line=${line%$'\r'}
        [ -n "$line" ] && fail "PowerShell cannot parse $line"
    done << PS
$(native "${ps_files[@]}" | "$ps" -NoProfile -NonInteractive -Command '$input | Where-Object { $_ } | ForEach-Object { $f = $_; $e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$e); $e | Select-Object -First 1 | ForEach-Object { "$f line $($_.Extent.StartLineNumber): $($_.Message)" } }' 2>&1)
PS
}

# Runs pack $1 through a throwaway Vigil: the jobs in $jobs, each job's
# metrics in metrics_<job>, as check_pack set them.
run_pack() {
    local name=$1 os work root j out rc line m listed
    case $(uname -s) in
        Linux) os=linux ;;
        Darwin) os=macos ;;
        *)
            printf '  skip  %s: --run runs on Linux and macOS; here, tools/Check-Pack.ps1 runs the Windows scripts\n' "$name"
            return
            ;;
    esac
    work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-pack.XXXXXX") || return
    root=$work/root
    mkdir -p "$root/packs/$name"
    cp -R app vendor "$root/"
    cp "packs/$name/pack.config" "$root/packs/$name/"
    if [ -d "packs/$name/$os" ]; then cp "packs/$name/$os"/* "$root/packs/$name/" 2> /dev/null; fi
    if ! out=$(bash "$root/app/vigil" --root "$root" init empty --instance check --backend file 2>&1); then
        fail "a throwaway Vigil would not start: $out"
        rm -rf "$work"
        return
    fi
    if ! out=$(bash "$root/app/vigil" --root "$root" pack enable "$name" 2>&1); then
        fail "vigil pack enable $name refused it: $out"
        rm -rf "$work"
        return
    fi
    for j in $jobs; do
        [ -f "$root/packs/$name/$j.sh" ] || continue
        out=$(bash "$root/app/vigil" --root "$root" run "${name}_$j" 2>&1)
        rc=$?
        # A secret is the operator's to give: this throwaway Vigil has none.
        if [ "$rc" -ne 0 ] && [[ $out =~ \(secret\ (secret:[A-Za-z0-9_]+)\ unavailable ]]; then
            printf '  skip  %s_%s: needs %s, which a throwaway Vigil does not have\n' "$name" "$j" "${BASH_REMATCH[1]}"
            continue
        fi
        if [ "$rc" -ne 0 ]; then
            fail "${name}_$j exited $rc here: $(cat "$root/logs/jobs/${name}_$j"/*.log 2> /dev/null | grep ' err ' | tail -2 | sed 's/^[^ ]* [^ ]* err //' | tr '\n' ' ')$out"
            continue
        fi
        eval "listed=\$metrics_$j"
        m=0
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            set -- $line
            m=$((m + 1))
            case " $listed " in *" $2 "*) ;; *) fail "${name}_$j printed metric $2, which pack.config does not list" ;; esac
            [[ ${3-} =~ ^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]] || fail "${name}_$j printed $2 as '${3-}', not a number"
        done << EOF
$(cat "$root/logs/jobs/${name}_$j"/*.log 2> /dev/null | sed -n 's/^[^ ]* [^ ]* out metric /metric /p')
EOF
        if [ "$m" -eq 0 ]; then
            fail "${name}_$j ran but printed no metric"
        else
            printf '  ran   %s_%s: %d metric line(s)\n' "$name" "$j" "$m"
        fi
    done
    rm -rf "$work"
}

check_pack() {
    local name=$1 dir=packs/$1 i sec key value job f os ext seen version vigil about mname mlist
    local -a words
    pack=$name
    jobs=''
    ps_files=()
    if ! [[ $name =~ ^[a-z][a-z0-9]*$ ]]; then
        fail "the name must be lower-case letters and digits, starting with a letter"
    fi
    if [ ! -f "$dir/pack.config" ]; then
        fail "no $dir/pack.config"
        return
    fi
    if ! vigil_config_parse "$dir/pack.config"; then
        for i in "${VIGIL_CFG_ERRORS[@]}"; do fail "pack.config line ${i%%	*}: ${i#*	}"; done
        return
    fi
    read_text "$dir/pack.config"
    check_common "$dir/pack.config"
    version='' vigil='' about=''
    i=0
    while [ "$i" -lt "${#VIGIL_CFG_KEY[@]}" ]; do
        sec=${VIGIL_CFG_SECTION[$i]} key=${VIGIL_CFG_KEY[$i]} value=${VIGIL_CFG_VALUE[$i]}
        case $sec:$key in
            pack:version) version=$value ;;
            pack:vigil) vigil=$value ;;
            pack:description) about=$value ;;
            pack:needs) [ -n "$value" ] || fail "pack.config line ${VIGIL_CFG_LINE[$i]}: needs is empty" ;;
            pack:*) fail "pack.config line ${VIGIL_CFG_LINE[$i]}: [pack] has no key $key (version, vigil, description, needs)" ;;
            job.*:file) fail "pack.config line ${VIGIL_CFG_LINE[$i]}: no file key: a job runs <job>.sh or <job>.ps1" ;;
        esac
        i=$((i + 1))
    done
    [[ $version =~ $semver ]] || fail "[pack] version must be like 1.0.0, not '$version'"
    [[ $vigil =~ $semver ]] || fail "[pack] vigil, the oldest Vigil it runs on, must be like 0.6.2, not '$vigil'"
    [ -n "$about" ] || fail "[pack] needs a description"

    for sec in "${VIGIL_CFG_SEC_NAME[@]}"; do
        case $sec in
            pack) ;;
            job.*)
                job=${sec#job.}
                [[ $job =~ $re_part ]] || fail "[job.$job]: a job name is lower-case letters, digits and _"
                jobs="$jobs $job"
                mname='' mlist=''
                i=0
                while [ "$i" -lt "${#VIGIL_CFG_KEY[@]}" ]; do
                    if [ "${VIGIL_CFG_SECTION[$i]}" = "$sec" ]; then
                        case ${VIGIL_CFG_KEY[$i]} in
                            metric_name) mname=${VIGIL_CFG_VALUE[$i]} ;;
                            metrics) mlist=${VIGIL_CFG_VALUE[$i]//,/ } ;;
                        esac
                    fi
                    i=$((i + 1))
                done
                [[ $mname =~ $re_metric ]] || fail "[job.$job] metric_name must be lower case, words joined by _ and parts by . (system.cpu), not '$mname'"
                read -ra words <<< "$mlist"
                [ "${#words[@]}" -gt 0 ] || fail "[job.$job] needs metrics: every name its script can print"
                for f in "${words[@]}"; do
                    [[ $f =~ $re_part ]] || fail "[job.$job] metric '$f' must be lower case, words joined by _ (used_pct)"
                done
                printf -v "metrics_$job" '%s' "${words[*]}"
                seen=0
                for os in linux macos windows; do
                    case $os in windows) ext=ps1 ;; *) ext=sh ;; esac
                    if [ -f "$dir/$os/$job.$ext" ]; then
                        seen=1
                        check_script "$dir/$os/$job.$ext" "${words[*]}"
                    fi
                done
                [ "$seen" -eq 1 ] || fail "[job.$job] has no script: $dir/linux/$job.sh, $dir/macos/$job.sh or $dir/windows/$job.ps1"
                ;;
            *) fail "pack.config: no section [$sec] here, only [pack] and [job.<name>]" ;;
        esac
    done
    parse_ps

    for f in "$dir"/*; do
        case ${f##*/} in
            pack.config | linux | macos | windows) ;;
            *) fail "$f: a pack holds only pack.config and linux/, macos/ and windows/" ;;
        esac
    done
    for os in linux macos windows; do
        [ -d "$dir/$os" ] || continue
        case $os in windows) ext=ps1 ;; *) ext=sh ;; esac
        for f in "$dir/$os"/*; do
            [ -e "$f" ] || continue
            job=${f##*/}
            case $job in
                *.$ext)
                    case " $jobs " in *" ${job%.$ext} "*) ;; *) fail "$f has no [job.${job%.$ext}] in pack.config" ;; esac
                    ;;
                *) fail "$f: $os/ holds only <job>.$ext scripts" ;;
            esac
        done
    done
    if [ "$name" != base ]; then
        read_text packs/README.md
        [[ $_text == *$'\n'"### $name"$'\n'* ]] || fail "packs/README.md needs a section: ### $name"
    fi

    if [ "$run" -eq 1 ] && [ "$failed" -eq "$before" ]; then
        run_pack "$name"
    elif [ "$run" -eq 1 ]; then
        printf '  skip  %s: not run until the checks above pass\n' "$name"
    fi
}

if [ "$#" -eq 0 ]; then
    for d in packs/*/; do
        d=${d%/}
        set -- "$@" "${d##*/}"
    done
fi
[ -n "$ps" ] || echo 'no PowerShell here: the .ps1 scripts are not parsed (CI parses them)'
for name in "$@"; do
    before=$failed
    check_pack "$name"
    [ "$failed" -eq "$before" ] && printf '  ok    %s\n' "$name"
done

if [ "$failed" -ne 0 ]; then
    echo "$failed to fix: CONTRIBUTING.md says what each rule is for"
    exit 1
fi
echo "$# pack(s) pass"
