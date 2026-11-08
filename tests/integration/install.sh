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
# Integration test: the installer (SPECIFICATION.md 18.7) on Linux and
# macOS, from release archives built by tools/release/package.sh. A
# tampered archive changes nothing; a fresh install unpacks, links the
# command and writes a configuration that passes pre-flight; an upgrade
# replaces app/ and never touches config/ or scripts/; uninstall removes it
# all. In system mode (sudo without a password, as on CI runners) the
# service is registered and running too.
#
# HOME is a throwaway folder, so the user-mode install touches nothing of
# the account's own.
#
# Exit code: 0 all passed, 1 any failed.

set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$(dirname "$here")")
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-inst.XXXXXX")
work=$(cd "$work" && pwd)
pass=0
fail=0

check() {
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
        printf '  PASS  %s\n' "$1"
    else
        fail=$((fail + 1))
        printf '  FAIL  %s: expected [%s] actual [%s]\n' "$1" "$2" "$3"
    fi
}

printf 'bash %s on %s\n' "$BASH_VERSION" "$(uname -s)"
# A release key for this run: the archives are signed with it, and the
# installer is given its public half with --key.
openssl genrsa -out "$work/release.key" 2048 2> /dev/null
openssl genrsa -out "$work/other.key" 2048 2> /dev/null
openssl rsa -in "$work/release.key" -pubout -out "$work/release.pem" 2> /dev/null
openssl rsa -in "$work/other.key" -pubout -out "$work/other.pem" 2> /dev/null
export VIGIL_SIGN_KEY=$work/release.key
# The first under umask 077, as the release workflow once built 0.2.2 and
# 0.3.0: their archives held app/ readable by its owner only.
(umask 077 && bash "$repo/tools/release/package.sh" 0.0.1-it "$work/r1" > /dev/null) || { printf 'packaging failed\n'; exit 1; }
bash "$repo/tools/release/package.sh" 0.0.2-it "$work/r2" > /dev/null || { printf 'packaging failed\n'; exit 1; }
a1=$work/r1/vigil-0.0.1-it.tar.gz
a2=$work/r2/vigil-0.0.2-it.tar.gz

# --- the archives' modes ------------------------------------------------------

# Folders 755, files 644, scripts 755, whatever the umask: any other mode is
# listed.
modes() { tar -tvzf "$1" | awk '$1 != "drwxr-xr-x" && $1 != "-rw-r--r--" && $1 != "-rwxr-xr-x" { print "        " $1, $NF }'; }
modes "$a1" > "$work/modes"
check 'the archive is readable by all, under umask 077' 0 "$(wc -l < "$work/modes" | tr -d ' ')"
head -5 "$work/modes"
modes "$work/r1/vigil-packs-0.0.1-it-linux.tar.gz" > "$work/modes"
check 'and so are the packs' 0 "$(wc -l < "$work/modes" | tr -d ' ')"
head -5 "$work/modes"
check 'app/vigil is executable' 1 "$(tar -tvzf "$a1" | awk '$NF ~ /\/app\/vigil$/ && $1 == "-rwxr-xr-x"' | wc -l | tr -d ' ')"

# --- a tampered archive -----------------------------------------------------

mkdir "$work/bad"
cp "$a1" "$work/bad/"
printf 'x' >> "$work/bad/vigil-0.0.1-it.tar.gz"
cp "$work/r1/SHA256SUMS" "$work/bad/"
HOME=$work/home sh "$repo/install.sh" --user --prefix "$work/badroot" --archive "$work/bad/vigil-0.0.1-it.tar.gz" --no-service < /dev/null > "$work/out" 2>&1
check 'a tampered archive is refused' 1 "$?"
check 'saying why' 1 "$(grep -c 'SHA-256 mismatch' "$work/out")"
check 'and nothing is installed' no "$([ -e "$work/badroot" ] && echo yes || echo no)"
rm "$work/bad/SHA256SUMS"
HOME=$work/home sh "$repo/install.sh" --user --prefix "$work/badroot" --archive "$work/bad/vigil-0.0.1-it.tar.gz" --no-service < /dev/null > /dev/null 2>&1
check 'an archive without SHA256SUMS is refused' 1 "$?"

# --- the signature, with --key ------------------------------------------------

# SHA256SUMS changed to match a changed archive: only the signature catches it.
mkdir "$work/forged"
cp "$work/bad/vigil-0.0.1-it.tar.gz" "$work/r1/SHA256SUMS.sig" "$work/forged/"
(cd "$work/forged" && { sha256sum vigil-0.0.1-it.tar.gz 2> /dev/null || shasum -a 256 vigil-0.0.1-it.tar.gz; } > SHA256SUMS)
HOME=$work/home sh "$repo/install.sh" --user --prefix "$work/badroot" --archive "$work/forged/vigil-0.0.1-it.tar.gz" --key "$work/release.pem" --no-service < /dev/null > "$work/out" 2>&1
check 'key: a forged SHA256SUMS is refused' 1 "$?"
check 'key: saying why' 1 "$(grep -c 'is not signed by the release key' "$work/out")"
check 'key: and nothing is installed' no "$([ -e "$work/badroot" ] && echo yes || echo no)"
mkdir "$work/nosig"
cp "$a1" "$work/r1/SHA256SUMS" "$work/nosig/"
HOME=$work/home sh "$repo/install.sh" --user --prefix "$work/badroot" --archive "$work/nosig/vigil-0.0.1-it.tar.gz" --key "$work/release.pem" --no-service < /dev/null > "$work/out" 2>&1
check 'key: without SHA256SUMS.sig, refused' 1 "$?"
check 'key: saying why' 1 "$(grep -c 'no SHA256SUMS.sig beside' "$work/out")"
HOME=$work/home sh "$repo/install.sh" --user --prefix "$work/badroot" --archive "$a1" --key "$work/other.pem" --no-service < /dev/null > /dev/null 2>&1
check 'key: signed by another key, refused' 1 "$?"
HOME=$work/home sh "$repo/install.sh" --user --prefix "$work/badroot" --archive "$a1" --key "$work/no.pem" --no-service < /dev/null > "$work/out" 2>&1
check 'key: a key that is not there, refused' 1 "$(grep -c 'no release key at' "$work/out")"
check 'key: nothing is installed by any of them' no "$([ -e "$work/badroot" ] && echo yes || echo no)"

# --- user mode: fresh install, upgrade, uninstall ----------------------------------

root=$work/root
export HOME=$work/home
mkdir -p "$HOME"
sh "$repo/install.sh" --user --prefix "$root" --archive "$a1" --instance it --backend file --no-service < /dev/null > "$work/out" 2>&1
rc=$?
check 'install succeeds' 0 "$rc"
[ "$rc" -eq 0 ] || sed 's/^/        /' "$work/out"
check 'a fresh install without --key checks no signature' 0 "$(grep -c 'verified SHA256SUMS' "$work/out")"
check 'the version is recorded' 0.0.1-it "$(cat "$root/app/VERSION" 2> /dev/null)"
check 'the command is linked' "$root/app/vigil" "$(readlink "$HOME/.local/bin/vigil")"
check 'init wrote the configuration' 1 "$(grep -c '^instance = it$' "$root/config/vigil.config" 2> /dev/null)"
"$HOME/.local/bin/vigil" precheck > /dev/null 2>&1
check 'the installed configuration passes pre-flight, through the link' 0 "$?"

printf '# my change\n' >> "$root/config/vigil.config"
printf 'echo mine\n' > "$root/scripts/mine.sh"
cfg=$(cksum < "$root/config/vigil.config")
# The installed key is the real release key, which did not sign these.
sh "$repo/install.sh" --user --prefix "$root" --archive "$a2" --no-service < /dev/null > "$work/out" 2>&1
check 'upgrade: checked against the installed key' 1 "$(grep -c "is not signed by the release key $root/app/release-key.pem" "$work/out")"
check 'upgrade: and refused' 0.0.1-it "$(cat "$root/app/VERSION" 2> /dev/null)"
sh "$repo/install.sh" --user --prefix "$root" --archive "$a2" --key "$work/release.pem" --no-service < /dev/null > "$work/out" 2>&1
rc=$?
check 'upgrade succeeds' 0 "$rc"
[ "$rc" -eq 0 ] || sed 's/^/        /' "$work/out"
check 'upgrade: the signature was checked' 1 "$(grep -c '^verified SHA256SUMS (signed by ' "$work/out")"
check 'says it upgraded' 1 "$(grep -c '^upgraded ' "$work/out")"
check 'app/ is the new version' 0.0.2-it "$(cat "$root/app/VERSION" 2> /dev/null)"
check 'the configuration is untouched' "$cfg" "$(cksum < "$root/config/vigil.config")"
check 'scripts are untouched' yes "$([ -f "$root/scripts/mine.sh" ] && echo yes)"
check 'no app.old is left' no "$([ -e "$root/app.old" ] && echo yes || echo no)"

"$HOME/.local/bin/vigil" uninstall --yes > /dev/null 2>&1
check 'uninstall succeeds' 0 "$?"
check 'the root is gone' no "$([ -e "$root" ] && echo yes || echo no)"
check 'the link is gone' no "$([ -L "$HOME/.local/bin/vigil" ] && echo yes || echo no)"

# --- system mode, with the service ---------------------------------------------------

if ! sudo -n true 2> /dev/null; then
    printf 'SKIP system mode: needs sudo without a password\n'
else
    root=/opt/vigil-inst-$$
    # From an archive like 0.2.2's and 0.3.0's, readable by its owner only:
    # the installer has to open app/ up for the service account.
    mkdir "$work/strict" "$work/strict/x"
    tar -xzf "$a1" -C "$work/strict/x" && chmod -R go-rwx "$work/strict/x"
    (cd "$work/strict/x" && tar -czf ../vigil-0.0.1-it.tar.gz vigil-0.0.1-it)
    (cd "$work/strict" && { sha256sum vigil-0.0.1-it.tar.gz 2> /dev/null || shasum -a 256 vigil-0.0.1-it.tar.gz; } > SHA256SUMS)
    sudo sh "$repo/install.sh" --system --prefix "$root" --archive "$work/strict/vigil-0.0.1-it.tar.gz" --instance it-sys < /dev/null > "$work/out" 2>&1
    rc=$?
    check 'system: install succeeds' 0 "$rc"
    [ "$rc" -eq 0 ] || sed 's/^/        /' "$work/out"
    check 'system: app/ is readable by all, from an owner-only archive' 0 "$(sudo find "$root/app" ! -perm -0444 | wc -l | tr -d ' ')"
    check 'system: and not writable by others' 0 "$(sudo find "$root/app" -perm -0002 | wc -l | tr -d ' ')"
    check 'system: the command is linked' "$root/app/vigil" "$(readlink /usr/local/bin/vigil)"
    check 'system: the service is active' active "$(sudo /usr/local/bin/vigil status 2> /dev/null | sed -n '1s/^service: \([a-z]*\).*/\1/p')"
    sudo sh "$repo/install.sh" --system --prefix "$root" --archive "$a2" --key "$work/release.pem" < /dev/null > "$work/out" 2>&1
    check 'system: upgrade succeeds' 0 "$?"
    check 'system: the service is active after the upgrade' active "$(sudo /usr/local/bin/vigil status 2> /dev/null | sed -n '1s/^service: \([a-z]*\).*/\1/p')"
    check 'system: app/ is the new version' 0.0.2-it "$(cat "$root/app/VERSION" 2> /dev/null)"
    sudo /usr/local/bin/vigil uninstall --yes > /dev/null 2>&1
    check 'system: uninstall succeeds' 0 "$?"
    check 'system: the root is gone' no "$([ -e "$root" ] && echo yes || echo no)"
    check 'system: the link is gone' no "$([ -L /usr/local/bin/vigil ] && echo yes || echo no)"
    [ "$(uname -s)" = Linux ] && sudo userdel vigil 2> /dev/null
fi

rm -rf "$work"
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
