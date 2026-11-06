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
# package.sh - builds the release archives the installers download
# (SPECIFICATION.md 18.7).
#
#   bash tools/release/package.sh <version> [<out dir>]     default: dist
#
# Writes, from the working tree:
#   vigil-<version>.tar.gz   Linux and macOS
#   vigil-<version>.zip      Windows
#   install.sh, install.ps1  the installers, also published on their own
#   vigil-packs-<version>-linux.tar.gz, -macos.tar.gz, -windows.zip
#                            one platform's packs, for vigil pack update
#   vigil_<version>-1_all.deb, vigil-<version>-1.noarch.rpm
#                            when nfpm is on PATH (linux-packages.sh)
#   SHA256SUMS               the SHA-256 of each, as sha256sum prints them
#   SHA256SUMS.sig           its signature, when VIGIL_SIGN_KEY names a key
#
# Each archive holds one folder, vigil-<version>/, with app/ (and
# app/VERSION), vendor/, install.sh, install.ps1, LICENSE and README.md, and
# packs/ with the scripts of its platforms: Linux and macOS in the .tar.gz,
# Windows in the .zip. The installer takes only its own (18.10).
# Needs tar and gzip, and for the .zip: zip, python3 or (Git Bash) PowerShell.

set -u
# Whatever umask this runs under, the archives hold folders 755 and files 644
# (scripts 755): a system install copies app/ as it is, and the service
# account has to read it. 0.2.2 and 0.3.0 were built under umask 077.
umask 022

[ "$#" -ge 1 ] || { printf 'usage: package.sh <version> [<out dir>]\n' >&2; exit 64; }
version=$1
case $version in
    '' | *[!0-9A-Za-z.-]*) printf 'package: not a version: %s\n' "$version" >&2; exit 64 ;;
esac
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
out=${2:-$repo/dist}
mkdir -p "$out" || exit 1
out=$(cd "$out" && pwd)
name=vigil-$version

stage=$(mktemp -d "${TMPDIR:-/tmp}/vigil-pkg.XXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/$name"
for f in app vendor install.sh install.ps1 LICENSE README.md; do
    cp -R "$repo/$f" "$stage/$name/" || exit 1
done
# A pack's folder for platforms $3..., under $1, from the repository's $2.
stage_pack() {
    local to=$1 from=$2 o
    shift 2
    mkdir -p "$to" && cp "$from/pack.config" "$to/" || exit 1
    for o in "$@"; do
        [ ! -d "$from/$o" ] || { mkdir -p "$to/$o" && cp "$from/$o"/* "$to/$o/"; } || exit 1
    done
}
printf '%s\n' "$version" > "$stage/$name/app/VERSION"
for p in "$repo"/packs/*/; do
    [ -f "$p/pack.config" ] || continue
    p=${p%/}
    stage_pack "$stage/$name/packs/${p##*/}" "$p" linux macos
done
chmod -R u+rwX,go+rX,go-w "$stage/$name" || exit 1
chmod 755 "$stage/$name/app/vigil" "$stage/$name/install.sh"

# Zips folder $1 of the stage to $2.
zip_it() {
    if command -v zip > /dev/null 2>&1; then
        (cd "$stage" && zip -qr "$2" "$1")
    elif ! command -v cygpath > /dev/null 2>&1 && command -v python3 > /dev/null 2>&1; then
        (cd "$stage" && python3 -I -m zipfile -c "$2" "$1")
    else
        powershell.exe -NoProfile -Command "Compress-Archive -Path '$(cygpath -w "$stage/$1")' -DestinationPath '$(cygpath -w "$2")'"
    fi
}

rm -f "$out/$name.tar.gz" "$out/$name.zip" "$out"/vigil-packs-"$version"-*
(cd "$stage" && tar -czf "$out/$name.tar.gz" "$name") || exit 1
# The .zip holds Windows' scripts instead.
rm -rf "$stage/$name/packs"
for p in "$repo"/packs/*/; do
    [ -f "$p/pack.config" ] || continue
    p=${p%/}
    stage_pack "$stage/$name/packs/${p##*/}" "$p" windows
done
zip_it "$name" "$out/$name.zip" || exit 1

# Each platform's packs on their own, flat.
pack_files=''
packs=vigil-packs-$version
for os in linux macos windows; do
    rm -rf "${stage:?}/$packs"
    for p in "$repo"/packs/*/; do
        [ -f "$p/pack.config" ] || continue
        p=${p%/}
        mkdir -p "$stage/$packs/${p##*/}" && cp "$p/pack.config" "$stage/$packs/${p##*/}/" || exit 1
        [ ! -d "$p/$os" ] || cp "$p/$os"/* "$stage/$packs/${p##*/}/" || exit 1
    done
    chmod -R u+rwX,go+rX,go-w "$stage/$packs" || exit 1
    if [ "$os" = windows ]; then
        zip_it "$packs" "$out/$packs-$os.zip" || exit 1
        pack_files="$pack_files $packs-$os.zip"
    else
        (cd "$stage" && tar -czf "$out/$packs-$os.tar.gz" "$packs") || exit 1
        pack_files="$pack_files $packs-$os.tar.gz"
    fi
done
cp "$repo/install.sh" "$repo/install.ps1" "$out/"

# The .deb and .rpm, from the .tar.gz just written, when nfpm is here: the
# release workflow has it, and checks they were built.
rm -f "$out"/vigil_"$version"-1_all.deb "$out"/vigil-"$version"-1.noarch.rpm
linux_files=''
if command -v "${NFPM:-nfpm}" > /dev/null 2>&1; then
    bash "$here/linux-packages.sh" "$version" "$out" || exit 1
    linux_files="vigil_${version}-1_all.deb vigil-$version-1.noarch.rpm"
else
    printf 'package: nfpm not found, so no .deb or .rpm
' >&2
fi

(
    cd "$out" || exit 1
    if command -v sha256sum > /dev/null 2>&1; then
        # shellcheck disable=SC2086
        sha256sum "$name.tar.gz" "$name.zip" install.sh install.ps1 $pack_files $linux_files
    else
        # shellcheck disable=SC2086
        shasum -a 256 "$name.tar.gz" "$name.zip" install.sh install.ps1 $pack_files $linux_files
    fi
) | sed 's/ \*/  /' > "$out/SHA256SUMS" || exit 1
# Signed in CI only, by .github/workflows/release.yml (17).
if [ -n "${VIGIL_SIGN_KEY-}" ]; then
    openssl dgst -sha256 -sign "$VIGIL_SIGN_KEY" -out "$out/SHA256SUMS.sig" "$out/SHA256SUMS" || exit 1
fi
printf 'packaged %s in %s\n' "$version" "$out"
cat "$out/SHA256SUMS"
