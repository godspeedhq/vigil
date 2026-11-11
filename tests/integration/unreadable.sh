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
# Integration test: what this account cannot read is never taken for missing
# (backlog 45). Closes folders of an install the way a system install's are
# closed to an ordinary account, then checks that each command says it cannot
# read them, names the folder and fails, rather than calling it absent: vigil
# config, pack enable and list, init, secret list and delete, precheck, self
# update --check, and a release_path that cannot be read. The twin of
# Unreadable.ps1. Root reads everything, so as root it only says so.
#
# Exit code: 0 all passed, 1 any failed.

set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$(dirname "$here")")
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-unread.XXXXXX")
work=$(cd "$work" && pwd)
root=$work/root
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

cleanup() {
    chmod -R u+rwx "$work" 2> /dev/null
    rm -rf "$work"
}
trap cleanup EXIT

if [ "$(id -u)" = 0 ]; then
    printf 'root reads everything: nothing to test\n0 passed, 0 failed\n'
    exit 0
fi

# A copy of the program with a VERSION, as a release has, so self update gets
# as far as reading its source.
mkdir -p "$root/config" "$root/scripts"
cp -R "$repo/app" "$root/app"
cp -R "$repo/packs" "$root/packs"
printf '0.0.1-it\n' > "$root/app/VERSION"
vigil() { "$BASH" "$root/app/vigil" --root "$root" "$@"; }
printf 'echo metric done 1\n' > "$root/scripts/x.sh"
cat > "$root/config/vigil.config" <<'EOF'
[vigil]
instance = unread

[runner.sh]
command = /bin/sh

[runners]
.sh = sh

[job.x]
file      = scripts/x.sh
run_every = 1m
secret    = X=secret:FOO
EOF
printf 'v\n' | vigil secret set FOO --stdin > /dev/null
check 'set up: the secret is stored' yes "$([ -f "$root/config/secrets/FOO" ] && echo yes || echo no)"

how='from this account: run this as the account that installed Vigil (sudo for a system install)'
# Every command below runs with config/ closed: listed and entered by no one.
chmod 000 "$root/config"
out=$(EDITOR=true vigil config 2>&1)
check 'config: refused' 1 "$?"
check 'config: says it cannot read the folder' "vigil: cannot read $root/config $how" "$out"
out=$(vigil pack enable base 2>&1)
check 'pack enable: refused' 1 "$?"
check 'pack enable: says it cannot read the folder' "vigil: cannot read $root/config $how" "$out"
out=$(vigil pack list 2>&1)
check 'pack list: refused, not every job off' 1 "$?"
check 'pack list: says it cannot read the folder' "vigil: cannot read $root/config $how" "$out"
out=$(vigil init 2>&1)
check 'init: refused' 1 "$?"
check 'init: says it cannot read the folder' "vigil: cannot read $root/config $how" "$(printf '%s\n' "$out" | tail -n 1)"
out=$(vigil secret list 2>&1)
check 'secret list: refused, not empty' 1 "$?"
check 'secret list: says it cannot read the folder' "vigil: cannot read $root/config from this account: secrets are set and read as the account Vigil runs as" "$out"
out=$(vigil secret delete FOO 2>&1)
check 'secret delete: refused, not "no secret"' 1 "$?"
check 'secret delete: says it cannot read the folder' "vigil: cannot read $root/config from this account: secrets are set and read as the account Vigil runs as" "$out"
out=$(vigil self update --check 2>&1)
check 'self update --check: refused, not GitHub' 1 "$?"
check 'self update --check: says the source cannot be read' "vigil: cannot read $root/config from this account, which says where releases come from: run this as the account that installed Vigil (sudo for a system install)" "$out"
out=$(vigil precheck 2>&1)
check 'precheck: refused' 1 "$?"
check 'precheck: the configuration cannot be read' yes "$(printf '%s\n' "$out" | grep -F "config file not readable: $root/config/vigil.config" > /dev/null && echo yes || echo no)"
chmod 755 "$root/config"
check 'secret delete: the secret is still there' yes "$([ -f "$root/config/secrets/FOO" ] && echo yes || echo no)"
check 'init: nothing left behind' '' "$(ls "$root/config" | grep '\.tmp\.')"
check 'and the configuration is untouched' yes "$(grep -F 'secret    = X=secret:FOO' "$root/config/vigil.config" > /dev/null && echo yes || echo no)"

# Only the secret store, then only the scripts, closed: precheck says why.
chmod 000 "$root/config/secrets"
out=$(vigil precheck 2>&1)
check 'precheck: a secret it cannot read is not "not found"' yes "$(printf '%s\n' "$out" | grep -F "secret:FOO unavailable: cannot read $root/config/secrets from this account" > /dev/null && echo yes || echo no)"
chmod 700 "$root/config/secrets"
chmod 000 "$root/scripts"
out=$(vigil precheck 2>&1)
check 'precheck: a script it cannot read is not "file not found"' yes "$(printf '%s\n' "$out" | grep -F "job.x: cannot read $root/scripts from this account" > /dev/null && echo yes || echo no)"
chmod 755 "$root/scripts"

# A release_path this account cannot read names the folder and the account,
# for a version asked for as for the latest.
mkdir -p "$work/releases"
chmod 000 "$work/releases"
cfg=$root/config/vigil.config
{ sed -n '1,2p' "$cfg"; printf 'release_path = %s\n' "$work/releases"; sed '1,2d' "$cfg"; } > "$cfg.new" && mv "$cfg.new" "$cfg"
me=$(id -un)
out=$(vigil self update --version 0.0.2-it 2>&1)
check 'release_path: a version that cannot be read is refused' 1 "$?"
check 'release_path: names the folder and the account' "vigil: cannot read Vigil 0.0.2-it from $work/releases (as $me): is it there, and readable by this account?" "$out"
out=$(vigil self update --check 2>&1)
check 'release_path: the latest names them too' "vigil: cannot read the latest release from $work/releases (as $me): is it there, and readable by this account?" "$out"
chmod 755 "$work/releases"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
