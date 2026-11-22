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
# client-jar.sh - a pack's Java, compiled (SPECIFICATION.md 18.10): each
# _<name>.java in folder <dir> (_client.java, a pack's own client;
# _probe.java, the generic probe, tools/probe) into _<name>.jar beside it,
# for a machine with a JRE, which cannot run a source file. The probe is
# built first, and is on the class path of the others. Each jar's SHA-256
# and the javac that built it are written into the scripts there (*.sh,
# *.ps1), in place of @<NAME>_JAR_SHA256@ and @<NAME>_JAR_JAVAC@
# (@CLIENT_JAR_SHA256@, @PROBE_JAR_SHA256@), so each script checks the jars
# it runs. packs.sh runs this on each platform's copy of a pack it releases;
# the repository holds the sources only.
#
#   client-jar.sh <dir> [<jar>...]
#
# The jars after <dir> are what the clients compile against (a pack's
# tools/<pack>/client.lib: Kafka's library, for the kafka pack): on javac's
# class path, never in a jar. Whoever installs the pack supplies them.
#
# The same source and the same javac give the same jar, byte for byte: Java
# 11 bytecode (javac --release 11), the classes in sorted order, no
# manifest, every entry dated 1980-01-01. So anyone can compile the sources
# with the javac a script names and compare digests.
#
# Needs javac and jar 17 or later (jar --date), JAVA_HOME's or the PATH's.
# Exit code: 0 built; 1 a failure; 64 a usage error.

set -u
umask 022

[ "$#" -ge 1 ] && [ -d "$1" ] && ls "$1"/_*.java > /dev/null 2>&1 ||
    { printf 'usage: client-jar.sh <folder holding _client.java or _probe.java> [<jar>...]\n' >&2; exit 64; }
dir=$(cd "$1" && pwd)
shift
# The class path to compile against: ; on Windows (Git Bash), : elsewhere.
cp='' sep=:
command -v cygpath > /dev/null 2>&1 && sep=';'
win() { if command -v cygpath > /dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
for j in "$@"; do
    [ -f "$j" ] || { printf 'client-jar: no such jar: %s\n' "$j" >&2; exit 1; }
    cp=$cp${cp:+$sep}$(win "$j")
done
bin=
[ -n "${JAVA_HOME-}" ] && [ -x "$JAVA_HOME/bin/javac" ] && bin=$JAVA_HOME/bin/
command -v "${bin}javac" > /dev/null 2>&1 && command -v "${bin}jar" > /dev/null 2>&1 ||
    { printf 'client-jar: javac and jar not found: a JDK 17 or later, in JAVA_HOME or on the PATH\n' >&2; exit 1; }
javac=$("${bin}javac" -version 2>&1 | awk '{ print $2; exit }')
case $javac in '' | *[!0-9A-Za-z.+_-]*) printf 'client-jar: cannot tell the javac version: %s\n' "$javac" >&2; exit 1 ;; esac

sha() {
    if command -v sha256sum > /dev/null 2>&1; then sha256sum < "$1" | cut -c1-64; else shasum -a 256 < "$1" | cut -c1-64; fi
}

work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-client-jar.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

# One source into its jar, $1 the name (client, probe).
build() {
    local name=$1 f sum
    rm -rf "$work/classes" && mkdir "$work/classes" || return 1
    "${bin}javac" --release 11 -encoding UTF-8 -nowarn ${cp:+-cp "$cp"} -d "$work/classes" "$dir/_$name.java" || return 1
    # Only classes, in the package-less root: in sorted order, so the jar is
    # the same whatever order the file system lists them in.
    (cd "$work/classes" && find . -type f | sed 's|^\./||' | LC_ALL=C sort) > "$work/list" || return 1
    grep -qv '^[A-Za-z0-9_$]*\.class$' "$work/list" && { printf 'client-jar: javac wrote more than classes\n' >&2; return 1; }
    set --
    while IFS= read -r f; do set -- "$@" "$f"; done < "$work/list"
    rm -f "$work/_$name.jar"
    (cd "$work/classes" && "${bin}jar" --create --file "$work/_$name.jar" --no-manifest --date 1980-01-01T00:00:02Z "$@") || return 1
    cp "$work/_$name.jar" "$dir/_$name.jar" || return 1
    sum=$(sha "$dir/_$name.jar")
    # Each script, with the digest and the javac in place, its mode kept.
    local up
    up=$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')
    for f in "$dir"/*.sh "$dir"/*.ps1; do
        [ -f "$f" ] || continue
        sed -e "s/@${up}_JAR_SHA256@/$sum/g" -e "s/@${up}_JAR_JAVAC@/$javac/g" "$f" > "$work/script" && cat "$work/script" > "$f" || return 1
    done
    printf 'client-jar: %s %s (javac %s)\n' "$dir/_$name.jar" "$sum" "$javac"
}

# The probe first: the others compile against it.
if [ -f "$dir/_probe.java" ]; then
    build probe || exit 1
    cp=$cp${cp:+$sep}$(win "$dir/_probe.jar")
fi
for src in "$dir"/_*.java; do
    name=${src##*/_}
    name=${name%.java}
    [ "$name" = probe ] && continue
    case $name in *[!a-z0-9]*) printf 'client-jar: not a name: _%s.java\n' "$name" >&2; exit 1 ;; esac
    build "$name" || exit 1
done
