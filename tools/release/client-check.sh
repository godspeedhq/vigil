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
# client-check.sh - compiles each pack's client against every library its
# client.lib names, the "check" ones too (SPECIFICATION.md 18.10): a client
# the release compiles against the oldest library it accepts must also
# compile against the newest, or a method the newest removed would fail a
# user's run. Builds nothing to keep.
#
#   client-check.sh [<pack>...]     every pack with a client.lib, or those named
#
# Needs a JDK 17 or later (JAVA_HOME's, or the PATH's) and curl.
# Exit code: 0 every client compiles against every library; 1 otherwise.

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

[ "$#" -gt 0 ] || set -- $(cd "$repo/packs" && for d in */; do [ -f "$d/client.lib" ] && printf '%s ' "${d%/}"; done)
rc=0
for name in "$@"; do
    d=$repo/packs/$name
    src=$(ls "$d"/*/_client.java 2> /dev/null | head -n 1)
    [ -f "$d/client.lib" ] && [ -n "$src" ] || { printf 'client-check: %s has no client.lib and _client.java\n' "$name" >&2; rc=1; continue; }
    while read -r use f url sum; do
        case $use in build | check) ;; *) continue ;; esac
        [ -f "$work/$f" ] || curl -fsSL --proto '=https' -o "$work/$f" "$url" || { printf 'client-check: cannot download %s\n' "$url" >&2; rc=1; continue; }
        if [ "$(sha "$work/$f")" != "$sum" ]; then
            printf 'client-check: %s does not match its SHA-256 in %s/client.lib\n' "$f" "$name" >&2
            rc=1
            continue
        fi
        lib=$work/$f
        command -v cygpath > /dev/null 2>&1 && lib=$(cygpath -w "$lib")
        rm -rf "$work/classes" && mkdir "$work/classes" || exit 1
        if "${bin}javac" --release 11 -encoding UTF-8 -nowarn -cp "$lib" -d "$work/classes" "$src" > "$work/out" 2>&1; then
            printf 'client-check: %s compiles against %s\n' "$name" "$f"
        else
            printf 'client-check: %s does not compile against %s:\n' "$name" "$f" >&2
            sed 's/^/  /' "$work/out" >&2
            rc=1
        fi
    done < "$d/client.lib"
done
exit "$rc"
