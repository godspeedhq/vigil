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
# client-jar.sh - a pack's client, compiled (SPECIFICATION.md 18.10): from
# the _client.java in folder <dir>, _client.jar beside it, for a machine
# with a JRE, which cannot run a source file. Its SHA-256 and the javac that
# built it are written into the scripts there (*.sh, *.ps1), in place of
# @CLIENT_JAR_SHA256@ and @CLIENT_JAR_JAVAC@, so each script checks the jar
# before it runs it. packs.sh runs this on each platform's copy of a pack it
# releases; the repository holds the source only.
#
#   client-jar.sh <dir>
#
# The same source and the same javac give the same jar, byte for byte: Java
# 11 bytecode (javac --release 11), the classes in sorted order, no
# manifest, every entry dated 1980-01-01. So anyone can compile the source
# with the javac a script names and compare digests.
#
# Needs javac and jar 17 or later (jar --date), JAVA_HOME's or the PATH's.
# Exit code: 0 built; 1 a failure; 64 a usage error.

set -u
umask 022

[ "$#" -eq 1 ] && [ -f "$1/_client.java" ] || { printf 'usage: client-jar.sh <folder holding _client.java>\n' >&2; exit 64; }
dir=$(cd "$1" && pwd)
bin=
[ -n "${JAVA_HOME-}" ] && [ -x "$JAVA_HOME/bin/javac" ] && bin=$JAVA_HOME/bin/
command -v "${bin}javac" > /dev/null 2>&1 && command -v "${bin}jar" > /dev/null 2>&1 ||
    { printf 'client-jar: javac and jar not found: a JDK 17 or later, in JAVA_HOME or on the PATH\n' >&2; exit 1; }

sha() {
    if command -v sha256sum > /dev/null 2>&1; then sha256sum < "$1" | cut -c1-64; else shasum -a 256 < "$1" | cut -c1-64; fi
}

work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-client-jar.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT
mkdir "$work/classes" || exit 1
"${bin}javac" --release 11 -encoding UTF-8 -nowarn -d "$work/classes" "$dir/_client.java" || exit 1
javac=$("${bin}javac" -version 2>&1 | awk '{ print $2; exit }')
case $javac in '' | *[!0-9A-Za-z.+_-]*) printf 'client-jar: cannot tell the javac version: %s\n' "$javac" >&2; exit 1 ;; esac

# Only classes, in the package-less root: in sorted order, so the jar is the
# same whatever order the file system lists them in.
(cd "$work/classes" && find . -type f | sed 's|^\./||' | LC_ALL=C sort) > "$work/list" || exit 1
grep -qv '^[A-Za-z0-9_$]*\.class$' "$work/list" && { printf 'client-jar: javac wrote more than classes\n' >&2; exit 1; }
set --
while IFS= read -r f; do set -- "$@" "$f"; done < "$work/list"
(cd "$work/classes" && "${bin}jar" --create --file "$work/_client.jar" --no-manifest --date 1980-01-01T00:00:02Z "$@") || exit 1
sum=$(sha "$work/_client.jar")
cp "$work/_client.jar" "$dir/_client.jar" || exit 1

# Each script, with the digest and the javac in place, its mode kept.
for f in "$dir"/*.sh "$dir"/*.ps1; do
    [ -f "$f" ] || continue
    sed -e "s/@CLIENT_JAR_SHA256@/$sum/g" -e "s/@CLIENT_JAR_JAVAC@/$javac/g" "$f" > "$work/script" && cat "$work/script" > "$f" || exit 1
done
printf 'client-jar: %s %s (javac %s)\n' "$dir/_client.jar" "$sum" "$javac"
