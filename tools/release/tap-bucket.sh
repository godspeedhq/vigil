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
# The Homebrew formula and the Scoop manifest of a release (backlog 30,
# step 2), from packaging/homebrew/vigil.rb.in and packaging/scoop/
# vigil.json.in, with the archives' hashes from the release's SHA256SUMS:
#   tap-bucket.sh <version> <SHA256SUMS> <out dir>
# writes <out dir>/Formula/vigil.rb and <out dir>/bucket/vigil.json, as the
# godspeedhq/homebrew-vigil and godspeedhq/scoop-vigil repositories lay
# them out. Check SHA256SUMS against SHA256SUMS.sig first: what it says is
# what the formula and manifest trust.
#
# VIGIL_PACKAGE_URL replaces the release's download folder in both, for
# tests that install from files of their own.

set -u

[ "$#" -eq 3 ] || { printf 'usage: tap-bucket.sh <version> <SHA256SUMS> <out dir>\n' >&2; exit 64; }
version=$1
sums=$2
out=$3
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
case $version in
    *[!0-9A-Za-z.-]* | '') printf 'tap-bucket: not a version: %s\n' "$version" >&2; exit 64 ;;
esac

# The hash SHA256SUMS gives file $1, or nothing.
hash_of() {
    awk -v f="$1" '$2 == f || $2 == "*" f { print $1; exit }' "$sums"
}
tgz=$(hash_of "vigil-$version.tar.gz")
zip=$(hash_of "vigil-$version.zip")
for h in "$tgz" "$zip"; do
    case $h in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) [ "${#h}" -eq 64 ] || { printf 'tap-bucket: a bad hash in %s\n' "$sums" >&2; exit 1; } ;;
        *) printf 'tap-bucket: %s has no hash for vigil-%s.tar.gz and .zip\n' "$sums" "$version" >&2; exit 1 ;;
    esac
done

release=https://github.com/godspeedhq/vigil/releases/download/v$version
mkdir -p "$out/Formula" "$out/bucket" || exit 1
fill() {
    sed -e "s|@VERSION@|$version|g" -e "s|@SHA256@|$2|g" "$1" |
        if [ -n "${VIGIL_PACKAGE_URL-}" ]; then sed "s|$release|$VIGIL_PACKAGE_URL|g"; else cat; fi
}
fill "$repo/packaging/homebrew/vigil.rb.in" "$tgz" > "$out/Formula/vigil.rb" || exit 1
fill "$repo/packaging/scoop/vigil.json.in" "$zip" > "$out/bucket/vigil.json" || exit 1
printf 'wrote %s/Formula/vigil.rb and %s/bucket/vigil.json for Vigil %s\n' "$out" "$out" "$version"
