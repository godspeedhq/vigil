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
# linux-packages.sh - builds the .deb and .rpm of Vigil (backlog 30, step 1)
# from the release archive package.sh wrote, so they hold exactly what it
# holds.
#
#   bash tools/release/linux-packages.sh <version> <dir>
#
# Reads <dir>/vigil-<version>.tar.gz and writes beside it:
#   vigil_<version>-1_all.deb
#   vigil-<version>-1.noarch.rpm
# The package definition and its scripts are in packaging/linux. Needs nfpm
# (https://nfpm.goreleaser.com), on PATH or named by NFPM.

set -u
umask 022

[ "$#" -eq 2 ] || { printf 'usage: linux-packages.sh <version> <dir>\n' >&2; exit 64; }
version=$1
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
out=$(cd "$2" && pwd) || exit 1
nfpm=${NFPM:-nfpm}
command -v "$nfpm" > /dev/null 2>&1 || { printf 'linux-packages: nfpm not found\n' >&2; exit 1; }
archive=$out/vigil-$version.tar.gz
[ -f "$archive" ] || { printf 'linux-packages: no %s\n' "$archive" >&2; exit 1; }

stage=$(mktemp -d "${TMPDIR:-/tmp}/vigil-linux.XXXXXX")
trap 'rm -rf "$stage"' EXIT
tar -xzf "$archive" -C "$stage" || exit 1
src=$stage/vigil-$version
pkg=$stage/pkg
mkdir -p "$pkg/packs"
cp -R "$src/app" "$pkg/app" && cp "$src/LICENSE" "$src/README.md" "$pkg/" || exit 1
# Only Linux's scripts: vigil init copies them from here into the root.
for p in "$src"/packs/*/; do
    p=${p%/}
    [ -f "$p/pack.config" ] || continue
    mkdir -p "$pkg/packs/${p##*/}" && cp "$p/pack.config" "$pkg/packs/${p##*/}/" || exit 1
    [ ! -d "$p/linux" ] || cp -R "$p/linux" "$pkg/packs/${p##*/}/" || exit 1
done
cp "$repo"/packaging/linux/nfpm.yaml "$repo"/packaging/linux/vigil.service "$pkg/" || exit 1
cp "$repo"/packaging/linux/postinstall.sh "$repo"/packaging/linux/preremove.sh "$repo"/packaging/linux/postremove.sh "$pkg/" || exit 1

# What a packaged Vigil says about itself (SPECIFICATION.md 18.6): who
# updates it, and its root, where the install script puts it too.
releases=https://github.com/godspeedhq/vigil/releases
printf 'manager = apt\nupgrade = sudo apt install ./vigil_<version>-1_all.deb, from %s\nroot    = /opt/vigil\n' "$releases" > "$pkg/PACKAGED.deb"
printf 'manager = dnf\nupgrade = sudo dnf install ./vigil-<version>-1.noarch.rpm, from %s\nroot    = /opt/vigil\n' "$releases" > "$pkg/PACKAGED.rpm"

chmod -R u+rwX,go+rX,go-w "$pkg" || exit 1
chmod 755 "$pkg/app/vigil" "$pkg"/*.sh

rm -f "$out/vigil_${version}-1_all.deb" "$out/vigil-$version-1.noarch.rpm"
for f in deb rpm; do
    (cd "$pkg" && VIGIL_VERSION=$version "$nfpm" package --config nfpm.yaml --packager "$f" --target "$out/") || exit 1
done
ls "$out/vigil_${version}-1_all.deb" "$out/vigil-$version-1.noarch.rpm" > /dev/null || exit 1
printf 'built vigil_%s-1_all.deb and vigil-%s-1.noarch.rpm in %s\n' "$version" "$version" "$out"
