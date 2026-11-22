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
# packs.sh - a packs release (SPECIFICATION.md 18.10): the archives of each
# pack whose version is new, and the index of every version, signed.
#
#   packs.sh <tag> <out dir> [<previous packs.index>]
#
# <tag> is packs-<YYYY.MM.DD>, or with .2, .3 for more in a day. Writes to
# <out dir>:
#   vigil-pack-<name>-<version>-linux.tar.gz, -macos.tar.gz, -windows.zip
#       a pack as packs/<name>/ holds it on that platform: pack.config and
#       that platform's scripts, in a folder <name>/. A platform the pack has
#       no scripts for has no archive. A pack with a _client.java there also
#       gets _client.jar, compiled from it, and its digest written into the
#       scripts (client-jar.sh).
#   packs.index
#       every version of every pack, the release its archives are in, and
#       each archive's SHA-256. Versions in <previous packs.index> are carried
#       over as they are; only a version not in it is built here.
#   packs.index.sig
#       when VIGIL_SIGN_KEY names the private release key.
#
# The index is text, one tab-separated record a line:
#   format   1
#   release  <tag>
#   pack     <name> <version> <oldest Vigil> <release> <source digest> <description>
#   file     <name> <version> <os> <archive> <sha256>
#   info     <name> <version> <key> <value>
# The source digest covers a pack's files: a pack whose files changed while
# its version did not is refused, as its version must go up. The info
# records are what vigil pack info shows, from pack.config: works_with,
# programs_linux, programs_macos, programs_windows and docs from [pack],
# each needs line, each secret its jobs read (secret), and each env line
# once (setting). A Vigil skips records it does not know.
#
# Needs tar, gzip, openssl, and for the .zip: zip, python3 or (Git Bash)
# PowerShell. For a pack with a _client.java: a JDK 17 or later.
# Exit code: 0 built; 1 a pack refused, or a failure; 64 a usage error.

set -u
umask 022

[ "$#" -ge 2 ] || { printf 'usage: packs.sh <tag> <out dir> [<previous packs.index>]\n' >&2; exit 64; }
tag=$1 prev=${3-}
case $tag in
    packs-[0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9] | packs-[0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9].[0-9]*) ;;
    *) printf 'packs: not a packs tag (packs-YYYY.MM.DD): %s\n' "$tag" >&2; exit 64 ;;
esac
[ -z "$prev" ] || [ -f "$prev" ] || { printf 'packs: no previous index at %s\n' "$prev" >&2; exit 64; }
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
mkdir -p "$2" || exit 1
out=$(cd "$2" && pwd)
command -v openssl > /dev/null 2>&1 || { printf 'packs: openssl not found\n' >&2; exit 1; }

stage=$(mktemp -d "${TMPDIR:-/tmp}/vigil-packs.XXXXXX")
trap 'rm -rf "$stage"' EXIT

sha() {
    if command -v sha256sum > /dev/null 2>&1; then sha256sum "$1" | cut -c1-64; else shasum -a 256 "$1" | cut -c1-64; fi
}
zip_it() {
    if command -v zip > /dev/null 2>&1; then
        (cd "$1" && zip -qr "$3" "$2")
    elif ! command -v cygpath > /dev/null 2>&1 && command -v python3 > /dev/null 2>&1; then
        (cd "$1" && python3 -I -m zipfile -c "$3" "$2")
    else
        powershell.exe -NoProfile -Command "Compress-Archive -Path '$(cygpath -w "$1/$2")' -DestinationPath '$(cygpath -w "$3")'"
    fi
}
# Key $2 of the [pack] section of manifest $1.
manifest() {
    awk -v k="$2" '
        /^\[/ { inpack = ($0 == "[pack]") ; next }
        inpack && $1 == k && $2 == "=" { sub(/^[^=]*= */, ""); sub(/[ \t]+$/, ""); print; exit }
    ' "$1"
}
# The info records of pack $2 version $3, from manifest $1 (see above).
info() {
    awk -v n="$2" -v v="$3" '
        function put(k, x) { gsub(/\t/, " ", x); printf "info\t%s\t%s\t%s\t%s\n", n, v, k, x }
        /^\[/ { sec = $0; next }
        /^[ \t]*[#;]/ || !/=/ { next }
        {
            k = $0; sub(/[ \t]*=.*/, "", k); sub(/^[ \t]+/, "", k)
            x = $0; sub(/^[^=]*=[ \t]*/, "", x); sub(/[ \t]+$/, "", x)
        }
        sec == "[pack]" && (k == "works_with" || k == "docs" || k ~ /^programs_(linux|macos|windows)$/) { one[k] = x }
        sec == "[pack]" && k == "needs" { needs[++nn] = x }
        sec ~ /^\[job\./ && k == "secret" {
            r = x; sub(/^[^=]*=/, "", r); sub(/^secret:/, "", r)
            if (!(("secret " r) in seen)) { seen["secret " r] = 1; secrets[++ns] = r }
        }
        sec ~ /^\[job\./ && k == "env" && !(("env " x) in seen) { seen["env " x] = 1; envs[++ne] = x }
        END {
            split("works_with programs_linux programs_macos programs_windows", ks, " ")
            for (i = 1; i <= 4; i++) if (ks[i] in one) put(ks[i], one[ks[i]])
            for (i = 1; i <= ns; i++) put("secret", secrets[i])
            for (i = 1; i <= nn; i++) put("needs", needs[i])
            for (i = 1; i <= ne; i++) put("setting", envs[i])
            if ("docs" in one) put("docs", one["docs"])
        }' "$1"
}
# The digest of a pack's source: every file's name and content, in order.
digest() {
    local d=$1 f
    (cd "$d" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do printf '%s ' "$f"; sha "$f"; done) |
        openssl dgst -sha256 | sed 's/^.*= *//'
}

new=$stage/packs.index
infos=$stage/info
printf 'format\t1\nrelease\t%s\n' "$tag" > "$new"
: > "$infos"
rc=0 built=0
for d in "$repo"/packs/*/; do
    [ -f "$d/pack.config" ] || continue
    d=${d%/}
    name=${d##*/}
    version=$(manifest "$d/pack.config" version)
    oldest=$(manifest "$d/pack.config" vigil)
    about=$(manifest "$d/pack.config" description | tr '\t' ' ')
    case $version in '' | *[!0-9A-Za-z.-]*) printf 'packs: %s has no valid version\n' "$name" >&2; rc=1; continue ;; esac
    sum=$(digest "$d")
    # From the files here, for a new version or a published one: the same
    # files either way, by its digest.
    info "$d/pack.config" "$name" "$version" >> "$infos"
    if [ -n "$prev" ] && old=$(awk -F '\t' -v n="$name" -v v="$version" '$1 == "pack" && $2 == n && $3 == v' "$prev") && [ -n "$old" ]; then
        # Published already: carried over, unless its files changed.
        if [ "$(printf '%s\n' "$old" | cut -f6)" != "$sum" ]; then
            printf 'packs: %s %s changed since it was published: give it a new version\n' "$name" "$version" >&2
            rc=1
        fi
        continue
    fi
    printf 'pack\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$version" "${oldest:-0}" "$tag" "$sum" "$about" >> "$new"
    for os in linux macos windows; do
        ext=sh
        [ "$os" = windows ] && ext=ps1
        ls "$d/$os"/*."$ext" > /dev/null 2>&1 || continue
        rm -rf "${stage:?}/$os" && mkdir -p "$stage/$os/$name" || exit 1
        cp "$d/pack.config" "$d/$os"/* "$stage/$os/$name/" || exit 1
        # A client in Java, compiled for a JRE, and its digest in the scripts.
        if [ -f "$stage/$os/$name/_client.java" ]; then
            bash "$here/client-jar.sh" "$stage/$os/$name" > /dev/null || { printf 'packs: cannot build the client of %s for %s\n' "$name" "$os" >&2; exit 1; }
        fi
        if grep -l '@CLIENT_JAR_' "$stage/$os/$name"/* > /dev/null 2>&1; then
            printf 'packs: %s for %s names a compiled client it has no _client.java for\n' "$name" "$os" >&2
            exit 1
        fi
        arch=vigil-pack-$name-$version-$os
        if [ "$os" = windows ]; then
            arch=$arch.zip
            rm -f "$out/$arch"
            zip_it "$stage/$os" "$name" "$out/$arch" || exit 1
        else
            arch=$arch.tar.gz
            (cd "$stage/$os" && tar -czf "$out/$arch" "$name") || exit 1
        fi
        printf 'file\t%s\t%s\t%s\t%s\t%s\n' "$name" "$version" "$os" "$arch" "$(sha "$out/$arch")" >> "$new"
    done
    built=$((built + 1))
    printf 'packs: %s %s\n' "$name" "$version"
done
[ "$rc" = 0 ] || exit 1
# Every version published before, as it was, with its info records unless
# they were just made from its files.
[ -z "$prev" ] || awk -F '\t' '$1 == "pack" || $1 == "file"' "$prev" >> "$new"
[ -z "$prev" ] || awk -F '\t' 'FNR == NR { had[$2 "\t" $3] = 1; next } $1 == "info" && !(($2 "\t" $3) in had)' "$infos" "$prev" >> "$infos"
# Packs then files, each by name and version.
{
    head -n 2 "$new"
    tail -n +3 "$new" | awk -F '\t' '$1 == "pack"' | LC_ALL=C sort -t "$(printf '\t')" -k2,2 -k3,3
    tail -n +3 "$new" | awk -F '\t' '$1 == "file"' | LC_ALL=C sort -t "$(printf '\t')" -k2,2 -k3,3 -k4,4
    # Each pack's in the order pack.config has them.
    LC_ALL=C sort -s -t "$(printf '\t')" -k2,2 -k3,3 "$infos"
} > "$out/packs.index"
if [ -n "${VIGIL_SIGN_KEY-}" ]; then
    openssl dgst -sha256 -sign "$VIGIL_SIGN_KEY" -out "$out/packs.index.sig" "$out/packs.index" || exit 1
fi
printf 'packs: %d new, index of %d versions in %s\n' "$built" "$(grep -c '^pack' "$out/packs.index")" "$out"
