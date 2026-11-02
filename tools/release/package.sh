#!/usr/bin/env bash
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
#   SHA256SUMS               the SHA-256 of each, as sha256sum prints them
#   SHA256SUMS.sig           its signature, when VIGIL_SIGN_KEY names a key
#
# Each archive holds one folder, vigil-<version>/, with app/ (and
# app/VERSION), vendor/, install.sh, install.ps1, LICENSE and README.md.
# Needs tar and gzip, and for the .zip: zip, python3 or (Git Bash) PowerShell.

set -u

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
printf '%s\n' "$version" > "$stage/$name/app/VERSION"
chmod 755 "$stage/$name/app/vigil" "$stage/$name/install.sh"

rm -f "$out/$name.tar.gz" "$out/$name.zip"
(cd "$stage" && tar -czf "$out/$name.tar.gz" "$name") || exit 1
if command -v zip > /dev/null 2>&1; then
    (cd "$stage" && zip -qr "$out/$name.zip" "$name") || exit 1
elif ! command -v cygpath > /dev/null 2>&1 && command -v python3 > /dev/null 2>&1; then
    (cd "$stage" && python3 -I -m zipfile -c "$out/$name.zip" "$name") || exit 1
else
    powershell.exe -NoProfile -Command "Compress-Archive -Path '$(cygpath -w "$stage/$name")' -DestinationPath '$(cygpath -w "$out/$name.zip")'" || exit 1
fi
cp "$repo/install.sh" "$repo/install.ps1" "$out/"

(
    cd "$out" || exit 1
    if command -v sha256sum > /dev/null 2>&1; then
        sha256sum "$name.tar.gz" "$name.zip" install.sh install.ps1
    else
        shasum -a 256 "$name.tar.gz" "$name.zip" install.sh install.ps1
    fi
) | sed 's/ \*/  /' > "$out/SHA256SUMS" || exit 1
# Signed in CI only, by .github/workflows/release.yml (17).
if [ -n "${VIGIL_SIGN_KEY-}" ]; then
    openssl dgst -sha256 -sign "$VIGIL_SIGN_KEY" -out "$out/SHA256SUMS.sig" "$out/SHA256SUMS" || exit 1
fi
printf 'packaged %s in %s\n' "$version" "$out"
cat "$out/SHA256SUMS"
