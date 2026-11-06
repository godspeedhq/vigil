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
# Integration test: vigil config (SPECIFICATION.md 16.6) on Linux and macOS,
# with scripted editors. A copy is saved only when valid, in one rename that
# keeps the file's mode; anything refused leaves the configuration exactly
# as it was, and no working folder is left behind.
#
# Exit code: 0 all passed, 1 any failed.

set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$(dirname "$here")")
vigil_cmd=$repo/app/vigil
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-ce.XXXXXX")
work=$(cd "$work" && pwd)
root=$work/root
cfg=$root/config/vigil.config
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

# vigil config with no terminal on stdin, as in CI.
vc() {
    out=$("$BASH" "$vigil_cmd" --root "$root" config "$@" < /dev/null 2>&1)
}

sum() { cksum < "$cfg"; }
leftovers() { find "$root/config" -name '.vigil-config.*' | wc -l | tr -d ' '; }

printf 'bash %s on %s\n' "$BASH_VERSION" "$(uname -s)"
mkdir -p "$root/config" "$root/scripts"
printf 'echo "metric ok 1"\n' > "$root/scripts/ok.sh"
cat > "$cfg" <<'EOF'
[vigil]
instance = ce

[runner.sh]
command = /bin/sh

[runners]
.sh = sh

[job.first]
file      = scripts/ok.sh
run_every = 1h
EOF
chmod 640 "$cfg"

# The editors: each gets the copy's path last.
e=$work/editors
mkdir "$e"
printf '#!/bin/sh\nexit 0\n' > "$e/none"
printf '#!/bin/sh\nexit 3\n' > "$e/fails"
printf '#!/bin/sh\nprintf "\\n[job.second]\\nfile      = scripts/ok.sh\\nrun_every = 30m\\n" >> "$1"\n' > "$e/add"
printf '#!/bin/sh\nprintf "\\nthis line is not a key\\n" >> "$1"\n' > "$e/error"
printf '#!/bin/sh\nprintf "\\n[job.third]\\nfile      = scripts/ok.sh\\nrun_every = often\\n" >> "$1"\n' > "$e/invalid"
# Someone else saves the configuration while this edit is open.
printf '#!/bin/sh\nprintf "\\n# changed by someone else\\n" >> "%s"\nprintf "\\n# mine\\n" >> "$1"\n' "$cfg" > "$e/race"
# An editor with an argument before the file.
printf '#!/bin/sh\n[ "$1" = --wait ] || exit 9\nprintf "\\n# with an argument\\n" >> "$2"\n' > "$e/args"
chmod 755 "$e"/*
unset VISUAL EDITOR

# --- nothing to save ---------------------------------------------------------

before=$(sum)
EDITOR=$e/none vc
check 'unchanged: exit 0' 0 "$?"
check 'unchanged: says so' yes "$(has 'no changes')"
check 'unchanged: the file is as it was' "$before" "$(sum)"
check 'unchanged: no working folder left' 0 "$(leftovers)"

EDITOR=$e/fails vc
check 'a failing editor: exit 1' 1 "$?"
check 'a failing editor: says so' yes "$(has 'exited with 3; nothing was changed')"
check 'a failing editor: the file is as it was' "$before" "$(sum)"

# --- refused -------------------------------------------------------------------

EDITOR=$e/error vc
check 'an ERROR: exit 1' 1 "$?"
check 'an ERROR: not saved' yes "$(has 'has problems and was not saved')"
check 'an ERROR: the report names the line' yes "$(has 'line 14:')"
check 'an ERROR: not at a terminal, it does not ask' no "$(has 'Edit again')"
check 'an ERROR: the file is as it was' "$before" "$(sum)"
check 'an ERROR: no working folder left' 0 "$(leftovers)"

EDITOR=$e/invalid vc
check 'an INVALID job: exit 1' 1 "$?"
check 'an INVALID job: the report names the job' yes "$(has 'INVALID  job.third')"
check 'an INVALID job: the file is as it was' "$before" "$(sum)"

EDITOR=$e/race vc
check 'changed during the edit: exit 1' 1 "$?"
check 'changed during the edit: says so' yes "$(has 'changed while it was being edited')"
check 'changed during the edit: the other change stays' 1 "$(grep -c 'changed by someone else' "$cfg")"
check 'changed during the edit: this edit is not in it' 0 "$(grep -c '# mine' "$cfg")"
check 'changed during the edit: this edit is kept beside it' 1 "$(grep -c '# mine' "$cfg.edited" 2> /dev/null)"
rm -f "$cfg.edited"
before=$(sum)

# --- saved ---------------------------------------------------------------------

EDITOR=$e/add vc
check 'a valid change: exit 0' 0 "$?"
check 'a valid change: says it is saved' yes "$(has "saved $cfg")"
check 'a valid change: it is in the file' 1 "$(grep -c '^\[job.second\]' "$cfg")"
check 'a valid change: the mode is kept' '-rw-r-----' "$(ls -l "$cfg" | cut -c1-10)"
check 'a valid change: no working folder left' 0 "$(leftovers)"
"$BASH" "$vigil_cmd" --root "$root" supervise --once > /dev/null 2>&1
grep -q 'second' "$root/logs/supervisor/jobs.log" 2> /dev/null && r=yes || r=no
check 'the supervisor runs the saved configuration' yes "$r"
# Its runs are short: let them end before the root goes.
sleep 3

before=$(sum)
VISUAL=$e/none EDITOR=$e/fails vc
check 'VISUAL comes before EDITOR' 0 "$?"
check 'VISUAL comes before EDITOR: nothing changed' "$before" "$(sum)"

EDITOR="$e/args --wait" vc
check 'an editor with arguments: exit 0' 0 "$?"
check 'an editor with arguments: saved' 1 "$(grep -c '# with an argument' "$cfg")"

# A setting that is a program's path is one path, spaces and all.
mkdir "$work/my editors"
printf '#!/bin/sh\nprintf "\\n# from a path with a space\\n" >> "$1"\n' > "$work/my editors/edit"
chmod 755 "$work/my editors/edit"
EDITOR="$work/my editors/edit" vc
check 'an editor whose path has a space: exit 0' 0 "$?"
check 'an editor whose path has a space: saved' 1 "$(grep -c '# from a path with a space' "$cfg")"

# --- what it refuses -----------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
    chmod 440 "$cfg"
    before=$(sum)
    EDITOR=$e/add vc
    check 'a file it cannot write: exit 1' 1 "$?"
    check 'a file it cannot write: says to run it as the owner' yes "$(has 'sudo vigil config')"
    check 'a file it cannot write: the file is as it was' "$before" "$(sum)"
    chmod 640 "$cfg"
else
    printf 'SKIP a file it cannot write: running as root\n'
fi

cp "$cfg" "$work/kept"
printf '[vigil]\nconfig_source = %s/fleet\n' "$work" > "$cfg"
before=$(sum)
EDITOR=$e/add vc
check 'a pointer file: exit 1' 1 "$?"
check 'a pointer file: names the source' yes "$(has "comes from $work/fleet")"
check 'a pointer file: the file is as it was' "$before" "$(sum)"

rm -f "$cfg"
EDITOR=$e/add vc
check 'no configuration: exit 1' 1 "$?"
check 'no configuration: points at vigil init' yes "$(has 'vigil init writes one')"

"$BASH" "$vigil_cmd" --root "$root" config extra < /dev/null > /dev/null 2>&1
check 'an argument is a usage error' 64 "$?"

rm -rf "$work"
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
