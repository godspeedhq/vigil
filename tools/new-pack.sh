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
# new-pack.sh - starts a pack: packs/<name>/ with a pack.config and one job's
# script for Linux, macOS and Windows, each with the header filled in as far
# as it can be. Every TODO left is for you; tools/check-pack.sh fails until
# none is left.
#
#   tools/new-pack.sh <name> [<job>]     the job is called status by default
#
# Exit code: 0 made, 1 refused (the pack exists, or a name is not allowed).

set -u

cd "$(dirname "$0")/.." || exit 1

name=${1-}
job=${2-status}
if [ -z "$name" ] || [ "$#" -gt 2 ]; then
    echo 'usage: tools/new-pack.sh <name> [<job>]' >&2
    exit 1
fi
if ! [[ $name =~ ^[a-z][a-z0-9]*$ ]]; then
    echo "not a pack name: $name (lower-case letters and digits, starting with a letter: mysql, redis)" >&2
    exit 1
fi
if ! [[ $job =~ ^[a-z][a-z0-9_]*$ ]]; then
    echo "not a job name: $job (lower-case letters, digits and _, starting with a letter)" >&2
    exit 1
fi
dir=packs/$name
if [ -e "$dir" ]; then
    echo "$dir is already there" >&2
    exit 1
fi

# The oldest Vigil the pack runs on: the latest release, unless you know an
# older one runs it too.
vigil=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2> /dev/null)
vigil=${vigil#v}
[[ $vigil =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || vigil=0.3.0

notice='# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.'

mkdir -p "$dir/linux" "$dir/macos" "$dir/windows" || exit 1

cat > "$dir/pack.config" << EOF
# $name - TODO: what this pack watches, in a line or two. See
# SPECIFICATION.md section 18.10 for this format.
#
# TODO: what it needs on the machine, and anything the operator sets first.
#
$notice

[pack]
version     = 0.1.0
# vigil: the oldest Vigil this pack runs on. vigil pack update refuses the
# pack on an older one.
vigil       = $vigil
description = TODO: $name, in a few words
# What vigil pack info shows besides: the servers it is meant for, the
# programs its scripts need on each platform (delete a line for none), and
# where it is explained.
works_with  = TODO: the $name versions it is meant for, and tested with
programs_linux = TODO: the programs the Linux scripts need, such as a client
programs_macos = TODO: the programs the macOS scripts need
programs_windows = TODO: the programs the Windows scripts need
docs        = https://github.com/godspeedhq/vigil/blob/main/packs/$name/README.md
# needs: what the jobs need that Vigil cannot see from them, one line each,
# shown by vigil pack enable and vigil pack list (a role, a page to turn on).
# Their secrets and env settings are shown without it. Delete it if none.
needs       = TODO: what $name must have before the jobs can run

[job.$job]
metric_name = $name
metrics     = up
run_every   = 1m
max_runtime = 30s
EOF

for os in linux macos; do
    case $os in linux) label=Linux ;; macos) label=macOS ;; esac
    cat > "$dir/$os/$job.sh" << EOF
#!/usr/bin/env bash
#
# $job.sh - TODO: what it reports, on $label
#
# TODO: how it reads it, and from where.
#
# Metrics:
#   up   1 when $name answers, 0 when it does not
#
# Example output:
#   metric up 1
#
# Reading the results (starting points: tune them to the machine):
#   Healthy  TODO
#   Watch    TODO
#   Act      TODO
#
# Requires: bash 3.2 or later, TODO: any command it uses
# Exit code: 0 on success, 1 if the data cannot be read
#
$notice

set -u

# TODO: read the real value. Report what you read, even a bad one: exit 1
# only when it cannot be read at all, with the reason on standard error.
echo 'metric up 1'
EOF
    chmod +x "$dir/$os/$job.sh"
done

cat > "$dir/windows/$job.ps1" << EOF
#Requires -Version 5.1

<#
.SYNOPSIS
    $job.ps1 - TODO: what it reports, on Windows
.DESCRIPTION
    TODO: how it reads it, and from where.

    Metrics:
        up   1 when $name answers, 0 when it does not

    Example output:
      metric up 1

    Reading the results (starting points: tune them to the machine):
      Healthy  TODO
      Watch    TODO
      Act      TODO

    Requires: Windows PowerShell 5.1 or PowerShell 7, TODO: anything else
    Exit code: 0 on success, 1 if the data cannot be read
.NOTES
$(printf '%s\n' "$notice" | sed 's/^# \{0,1\}/    /; s/^    $//')
#>

\$ErrorActionPreference = 'Stop'

# TODO: read the real value. Report what you read, even a bad one: exit 1
# only when it cannot be read at all, with the reason on standard error.
Write-Output 'metric up 1'
EOF

# Its page: everything about it, in one place, as every pack's.
cat > "$dir/README.md" << EOF
# The $name pack

TODO: what it watches, on which servers, and how it reads them.

TODO: how to turn it on: what the server needs (a role, a page), vigil pack
enable $name, and the settings and secrets of its jobs.

## What it needs

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| On the Vigil machine | TODO | | |

## Its jobs

| Job | Reports | Every |
| --- | --- | --- |
| \`${name}_$job\` | TODO | minute |

## What to alert on

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| \`$name.up\` | 1 | | 0 | TODO: what the real server showed |

## How it was tested

TODO: when, where, against which versions, the trouble caused on purpose, the
results, and a link to the console output (CONTRIBUTING.md, Tests and
evidence).

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack)
EOF

cat << EOF
made $dir:
  $dir/pack.config
  $dir/README.md
  $dir/linux/$job.sh
  $dir/macos/$job.sh
  $dir/windows/$job.ps1

Next:
  1. Fill in every TODO, its page too. Delete a platform's script if the job
     cannot run there.
  2. Add an entry for $name to packs/README.md: ### $name, a line or two, and
     a link to its page.
  3. python tools/pack-grid.py . $name   puts the grid of its metrics on its page
  4. tools/check-pack.sh $name          checks it
     tools/check-pack.sh --run $name    and runs its jobs here, through Vigil
  5. Open a pull request. CONTRIBUTING.md has the rest.
EOF
