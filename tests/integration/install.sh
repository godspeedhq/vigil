#!/usr/bin/env bash
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
bash "$repo/tools/release/package.sh" 0.0.1-it "$work/r1" > /dev/null || { printf 'packaging failed\n'; exit 1; }
bash "$repo/tools/release/package.sh" 0.0.2-it "$work/r2" > /dev/null || { printf 'packaging failed\n'; exit 1; }
a1=$work/r1/vigil-0.0.1-it.tar.gz
a2=$work/r2/vigil-0.0.2-it.tar.gz

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

# --- user mode: fresh install, upgrade, uninstall ----------------------------------

root=$work/root
export HOME=$work/home
mkdir -p "$HOME"
sh "$repo/install.sh" --user --prefix "$root" --archive "$a1" --instance it --backend file --no-service < /dev/null > "$work/out" 2>&1
rc=$?
check 'install succeeds' 0 "$rc"
[ "$rc" -eq 0 ] || sed 's/^/        /' "$work/out"
check 'the version is recorded' 0.0.1-it "$(cat "$root/app/VERSION" 2> /dev/null)"
check 'the command is linked' "$root/app/vigil" "$(readlink "$HOME/.local/bin/vigil")"
check 'init wrote the configuration' 1 "$(grep -c '^instance = it$' "$root/config/vigil.config" 2> /dev/null)"
"$HOME/.local/bin/vigil" precheck > /dev/null 2>&1
check 'the installed configuration passes pre-flight, through the link' 0 "$?"

printf '# my change\n' >> "$root/config/vigil.config"
printf 'echo mine\n' > "$root/scripts/mine.sh"
cfg=$(cksum < "$root/config/vigil.config")
sh "$repo/install.sh" --user --prefix "$root" --archive "$a2" --no-service < /dev/null > "$work/out" 2>&1
check 'upgrade succeeds' 0 "$?"
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
    sudo sh "$repo/install.sh" --system --prefix "$root" --archive "$a1" --instance it-sys < /dev/null > "$work/out" 2>&1
    rc=$?
    check 'system: install succeeds' 0 "$rc"
    [ "$rc" -eq 0 ] || sed 's/^/        /' "$work/out"
    check 'system: the command is linked' "$root/app/vigil" "$(readlink /usr/local/bin/vigil)"
    check 'system: the service is active' active "$(sudo /usr/local/bin/vigil status 2> /dev/null | sed -n '1s/^service: \([a-z]*\).*/\1/p')"
    sudo sh "$repo/install.sh" --system --prefix "$root" --archive "$a2" < /dev/null > "$work/out" 2>&1
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
