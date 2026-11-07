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
# The MacPorts Portfile of a release (backlog 30, step 3), from
# packaging/macports/Portfile.in:
#   portfile.sh <version> <vigil-<version>.tar.gz> <SHA256SUMS> <out dir>
# writes <out dir>/sysutils/vigil/Portfile, as the macports-ports tree lays
# it out. MacPorts wants the archive's RIPEMD-160 and size as well as its
# SHA-256, which SHA256SUMS does not hold, so this reads the archive itself,
# and refuses one whose SHA-256 is not the one SHA256SUMS gives. Check
# SHA256SUMS against SHA256SUMS.sig first.

set -u

[ "$#" -eq 4 ] || { printf 'usage: portfile.sh <version> <tar.gz> <SHA256SUMS> <out dir>\n' >&2; exit 64; }
version=$1
tgz=$2
sums=$3
out=$4
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
case $version in
    *[!0-9A-Za-z.-]* | '') printf 'portfile: not a version: %s\n' "$version" >&2; exit 64 ;;
esac
[ "${tgz##*/}" = "vigil-$version.tar.gz" ] || { printf 'portfile: %s is not vigil-%s.tar.gz\n' "$tgz" "$version" >&2; exit 64; }

want=$(awk -v f="vigil-$version.tar.gz" '$2 == f || $2 == "*" f { print $1; exit }' "$sums")
[ "${#want}" -eq 64 ] || { printf 'portfile: %s has no hash for vigil-%s.tar.gz\n' "$sums" "$version" >&2; exit 1; }
sha256=$(openssl dgst -sha256 "$tgz" | awk '{ print $NF }')
[ "$sha256" = "$want" ] || { printf 'portfile: %s does not match SHA256SUMS\n' "$tgz" >&2; exit 1; }
rmd160=$(openssl dgst -rmd160 "$tgz" 2> /dev/null | awk '{ print $NF }')
# OpenSSL 3 keeps RIPEMD-160 in its legacy provider on some builds.
[ "${#rmd160}" -eq 40 ] || rmd160=$(openssl dgst -provider legacy -provider default -rmd160 "$tgz" | awk '{ print $NF }')
[ "${#rmd160}" -eq 40 ] || { printf 'portfile: openssl cannot compute RIPEMD-160\n' >&2; exit 1; }
size=$(wc -c < "$tgz" | tr -d ' ')

mkdir -p "$out/sysutils/vigil" || exit 1
sed -e "s|@VERSION@|$version|g" -e "s|@RMD160@|$rmd160|g" -e "s|@SHA256@|$sha256|g" -e "s|@SIZE@|$size|g" \
    "$repo/packaging/macports/Portfile.in" > "$out/sysutils/vigil/Portfile" || exit 1
printf 'wrote %s/sysutils/vigil/Portfile for Vigil %s\n' "$out" "$version"
