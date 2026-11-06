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
# Integration test: a packaged program (SPECIFICATION.md 18.6) on Linux and
# macOS. The program is laid out as a package lays it out, read-only, with
# app/PACKAGED naming its root elsewhere: Vigil finds that root, vigil init
# puts the package's packs in it, self update and uninstall leave the program
# to its package manager, and nothing is ever written into the program.
#
# Exit code: 0 all passed, 1 any failed.

set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$(dirname "$here")")
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-pk.XXXXXX")
work=$(cd "$work" && pwd)
prog=$work/prog
data=$work/data
pass=0
fail=0

check() {
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
        printf '  PASS  %s\n' "$1"
    else
        fail=$((fail + 1))
        printf '  FAIL  %s: expected [%s] actual [%s]\n' "$1" "$2" "$3"
        [ -z "${out-}" ] || printf '%s\n' "$out" | sed 's/^/        /'
    fi
}

# Whether the output in $out has a line containing $1.
has() {
    if printf '%s\n' "$out" | grep -F -e "$1" > /dev/null; then echo yes; else echo no; fi
}

# The packaged vigil, with no terminal and no update check.
pv() {
    out=$(VIGIL_NO_UPDATE_CHECK=1 "$BASH" "$prog/app/vigil" "$@" < /dev/null 2>&1)
}

# Every file of the program with its checksum: what must never change.
program() { (cd "$prog" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do cksum "$f"; done); }

printf 'bash %s on %s\n' "$BASH_VERSION" "$(uname -s)"
case $(uname -s) in Darwin) os=macos ;; *) os=linux ;; esac

# The program as a package installs it: app/ and packs/ side by side.
mkdir -p "$prog"
cp -R "$repo/app" "$prog/app"
cp -R "$repo/packs" "$prog/packs"
printf '9.9.9\n' > "$prog/app/VERSION"
cat > "$prog/app/PACKAGED" <<EOF
manager = testpkg
upgrade = sudo testpkg upgrade vigil
root    = $data
EOF
chmod -R a-w "$prog"
before=$(program)

# --- the root ------------------------------------------------------------------

pv about
check 'the root is the one PACKAGED names' yes "$(has "Installed   $data")"
check 'about names the program and its package manager' yes "$(has "Program     $prog, by testpkg")"

mkdir -p "$work/other"
out=$(VIGIL_ROOT=$work/other VIGIL_NO_UPDATE_CHECK=1 "$BASH" "$prog/app/vigil" about 2>&1)
check 'VIGIL_ROOT comes before PACKAGED' yes "$(has "Installed   $work/other")"
out=$(VIGIL_ROOT=$work/other VIGIL_NO_UPDATE_CHECK=1 "$BASH" "$prog/app/vigil" --root "$prog" about 2>&1)
check '--root comes before VIGIL_ROOT' yes "$(has "Installed   $prog")"

# --- vigil init ------------------------------------------------------------------

pv init --instance pk --backend file
check 'init: exit 0' 0 "$?"
check 'init: writes the configuration in the root' yes "$([ -f "$data/config/vigil.config" ] && echo yes || echo no)"
check 'init: puts the packs in the root' yes "$([ -f "$data/packs/base/pack.config" ] && echo yes || echo no)"
check "init: only this platform's scripts, flat" yes "$([ -f "$data/packs/base/cpu.sh" ] && [ ! -e "$data/packs/base/cpu.ps1" ] && [ ! -d "$data/packs/base/$os" ] && echo yes || echo no)"
check 'init: turns the base pack on' 1 "$(grep -c '^# pack base:' "$data/config/vigil.config")"

pv run base_cpu
check 'a pack job runs from the root' 0 "$?"
check 'its log is in the root' yes "$([ -d "$data/logs/jobs/base_cpu" ] && echo yes || echo no)"

# A pack already in the root stays as it is.
chmod u+w "$data/packs/base/pack.config"
printf '# changed here\n' >> "$data/packs/base/pack.config"
mv "$data/config/vigil.config" "$work/kept.config"
pv init --instance pk --backend file
check 'init again: exit 0' 0 "$?"
check 'init again: a pack already there is kept' 1 "$(grep -c '^# changed here' "$data/packs/base/pack.config")"

# --- what is left to the package manager ------------------------------------------

pv self update
check 'self update: exit 1' 1 "$?"
check 'self update: names the package manager and its command' yes "$(has 'Vigil was installed by testpkg: update it with sudo testpkg upgrade vigil')"

# Even when the configuration names a version, which otherwise has its own refusal.
cfg=$data/config/vigil.config
awk '{ print } /^instance = pk$/ { print "version = 9.9.8" }' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
check 'the configuration names a version' 1 "$(grep -c '^version = 9.9.8$' "$cfg")"
pv self update
check 'self update with a version configured: still the package manager' yes "$(has 'installed by testpkg')"

pv uninstall --yes
check 'uninstall: exit 1' 1 "$?"
check 'uninstall: says to use the package manager' yes "$(has 'installed by testpkg: remove it with that')"
check 'uninstall: the root is kept' yes "$([ -f "$cfg" ] && echo yes || echo no)"

# --- the program itself ----------------------------------------------------------

out=''
check 'nothing was written into the program' "$before" "$(program)"

# A program that is not packaged keeps the root above app/, and init copies no
# packs: the install script does that.
mkdir -p "$work/plain"
out=$(VIGIL_NO_UPDATE_CHECK=1 "$BASH" "$repo/app/vigil" --root "$work/plain" init --instance plain --backend file < /dev/null 2>&1)
check 'not packaged: init copies no packs' no "$([ -e "$work/plain/packs" ] && echo yes || echo no)"

chmod -R u+w "$prog" "$data" 2> /dev/null
rm -rf "$work"
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
