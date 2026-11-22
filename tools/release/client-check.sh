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
# client-check.sh - a pack's Java, checked as a release would build it
# (SPECIFICATION.md 18.10), so a pull request finds what a tagged release
# would. For each pack:
#   - its client, with the probe beside it, compiles against every library
#     its tools/<pack>/client.lib names, the "check" ones too: a client the
#     release compiles against the oldest library it accepts must also
#     compile against the newest, or a method the newest removed would fail
#     a user's run. A pack with no client.lib compiles against nothing.
#   - each platform's jars build with client-jar.sh, against the "build"
#     libraries, as packs.sh builds them, and no script is left with a
#     digest unwritten.
# Builds nothing to keep.
#
#   client-check.sh [<pack>...]     every pack with Java, or those named
#
# Needs a JDK 17 or later (JAVA_HOME's, or the PATH's) and curl.
# Exit code: 0 every pack checked; 1 otherwise.

set -u
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
bin=
[ -n "${JAVA_HOME-}" ] && [ -x "$JAVA_HOME/bin/javac" ] && bin=$JAVA_HOME/bin/
command -v "${bin}javac" > /dev/null 2>&1 || { printf 'client-check: javac not found: a JDK 17 or later, in JAVA_HOME or on the PATH\n' >&2; exit 1; }
sha() {
    if command -v sha256sum > /dev/null 2>&1; then sha256sum < "$1" | cut -c1-64; else shasum -a 256 < "$1" | cut -c1-64; fi
}
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-client-check.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT
mkdir "$work/lib" || exit 1

# Every pack with Java: a _*.java in any of its platform folders.
[ "$#" -gt 0 ] || set -- $(cd "$repo/packs" && ls */*/_*.java 2> /dev/null | cut -d/ -f1 | sort -u)
[ "$#" -gt 0 ] || { printf 'client-check: no pack has Java\n'; exit 0; }

# A library named in client.lib, downloaded once and checked against its
# SHA-256; its path in lib.
fetch() {
    lib=$work/lib/$2
    if [ ! -f "$lib" ]; then
        curl -fsSL --proto '=https' -o "$lib.part" "$3" && mv "$lib.part" "$lib" ||
            { printf 'client-check: cannot download %s\n' "$3" >&2; return 1; }
    fi
    [ "$(sha "$lib")" = "$4" ] || { printf 'client-check: %s does not match its SHA-256 in %s/client.lib\n' "$2" "$1" >&2; rm -f "$lib"; return 1; }
    command -v cygpath > /dev/null 2>&1 && lib=$(cygpath -w "$lib")
    return 0
}

# javac of a platform folder's Java against a class path ($2, may be empty).
compiles() {
    local srcs=() f
    for f in "$1"/_*.java; do srcs+=("$f"); done
    rm -rf "$work/classes" && mkdir "$work/classes" || return 1
    "${bin}javac" --release 11 -encoding UTF-8 -nowarn ${2:+-cp "$2"} -d "$work/classes" "${srcs[@]}" > "$work/out" 2>&1
}

rc=0
for name in "$@"; do
    p=$repo/packs/$name
    t=$repo/tools/$name
    first=$(ls -d "$p"/*/ 2> /dev/null | while read -r d; do ls "$d"_*.java > /dev/null 2>&1 && { printf '%s\n' "${d%/}"; break; }; done)
    [ -n "$first" ] || { printf 'client-check: %s has no Java\n' "$name" >&2; rc=1; continue; }

    # Every library, each alone; with none, against nothing.
    build=() checked=0
    if [ -f "$t/client.lib" ]; then
        while read -r use f url sum; do
            case $use in build | check) ;; *) continue ;; esac
            fetch "$name" "$f" "$url" "$sum" || { rc=1; continue; }
            [ "$use" = build ] && build+=("$work/lib/$f")
            checked=$((checked + 1))
            if compiles "$first" "$lib"; then
                printf 'client-check: %s compiles against %s\n' "$name" "$f"
            else
                printf 'client-check: %s does not compile against %s:\n' "$name" "$f" >&2
                sed 's/^/  /' "$work/out" >&2
                rc=1
            fi
        done < "$t/client.lib"
        [ "$checked" -gt 0 ] || { printf 'client-check: %s/client.lib names no library\n' "$name" >&2; rc=1; }
    elif compiles "$first" ''; then
        printf 'client-check: %s compiles, with no library\n' "$name"
    else
        printf 'client-check: %s does not compile:\n' "$name" >&2
        sed 's/^/  /' "$work/out" >&2
        rc=1
    fi

    # Each platform's jars, as packs.sh builds them, from a copy.
    for d in "$p"/*/; do
        d=${d%/}
        ls "$d"/_*.java > /dev/null 2>&1 || continue
        os=${d##*/}
        rm -rf "$work/stage" && mkdir -p "$work/stage" && cp -R "$d" "$work/stage/$name" || exit 1
        if ! bash "$here/client-jar.sh" "$work/stage/$name" ${build[@]+"${build[@]}"} > "$work/out" 2>&1; then
            printf 'client-check: %s for %s does not build:\n' "$name" "$os" >&2
            sed 's/^/  /' "$work/out" >&2
            rc=1
            continue
        fi
        if grep -lE '@[A-Z]+_JAR_(SHA256|JAVAC)@' "$work/stage/$name"/* > "$work/out" 2> /dev/null; then
            printf 'client-check: %s for %s: a script still has a digest unwritten:\n' "$name" "$os" >&2
            sed "s#^$work/stage/#  #" "$work/out" >&2
            rc=1
            continue
        fi
        for j in "$work/stage/$name"/_*.jar; do
            printf 'client-check: %s for %s built %s %s\n' "$name" "$os" "${j##*/}" "$(sha "$j")"
        done
    done
done
exit "$rc"
