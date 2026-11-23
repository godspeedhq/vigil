#Requires -Version 5.1

<#
.SYNOPSIS
    processes.ps1 - inside each Erlang VM: the longest mailboxes, the processes
.DESCRIPTION
    holding the most memory, the busiest

    Reads every process of each node in BEAM_DIST (<name>=<node> separated by
    ;) with its cookie (BEAM_COOKIE, a secret), by _beam.escript beside this
    script, with Erlang's escript (BEAM_ERLANG, where Erlang is, else the
    PATH's): its mailbox, memory and reductions, one process at a time. Past
    20,000 processes, the first 20,000. Each process is named by its
    registered name, else by what it runs (a gen_server's module).

    WARNING: a node's cookie lets whoever holds it run anything on that node.
    This pack never changes anything: it only reads, and _beam.escript lists
    every call it makes. Give Vigil the cookie only if you accept that.

    Metrics:
      nodes                     the nodes named in BEAM_DIST
      up                        1 when the node answers, else 0, tagged
                                node=<its name> and source=dist
      processes_read            the processes read
      processes_not_read        past 20,000, the processes left out
      mailbox_messages          messages waiting, in every mailbox read
      mailboxes_over_1000       processes with more than 1,000 waiting
      mailbox                   messages waiting for one of the ten longest
                                mailboxes, tagged node=<its name>,
                                source=dist and process=<its name>
      process_memory_bytes      memory of one of the ten largest processes
                                (its heap, stack and mailbox), tagged the same
      process_reductions_count  work done by one of the ten busiest, since it
                                started (a running total), tagged the same

    Example output:
      metric nodes 1
      metric up 1 node=n28 source=dist
      metric processes_read 50 node=n28 source=dist
      metric processes_not_read 0 node=n28 source=dist
      metric mailbox_messages 0 node=n28 source=dist
      metric mailboxes_over_1000 0 node=n28 source=dist
      metric process_memory_bytes 230496 node=n28 source=dist process=code_server
      metric process_memory_bytes 34528 node=n28 source=dist process=application_controller
      metric process_reductions_count 121107 node=n28 source=dist process=code_server

    Reading the results (starting points: tune them to the node):
      Healthy  mailbox_messages near 0; mailboxes_over_1000 0; the largest
               processes the same ones, at about the same size, run to run.
      Watch    a mailbox growing run after run: that process takes messages
               in faster than it handles them; one process_memory_bytes
               climbing: it holds on to state, or to large binaries.
      Act      mailboxes_over_1000 above 0 and rising: a process is falling
               behind, and its memory grows with its mailbox until the VM
               runs out; the busiest is the same process every run, far ahead
               of the rest: a hot spot.

    Requires: Windows PowerShell 5.1 or PowerShell 7; Erlang/OTP 25 or later (escript.exe)
    Exit code: 0 on success, nodes up or down, or none named; 1 if escript.exe is
      missing, BEAM_DIST or BEAM_COOKIE is wrong, or a node refused the cookie
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
#>

$ErrorActionPreference = 'Stop'

$dist = @(([string]$env:BEAM_DIST) -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
Write-Output "metric nodes $($dist.Count)"
if ($dist.Count -eq 0) { exit 0 }

# Erlang's escript.exe: BEAM_ERLANG's (where Erlang is, or its bin), else
# the PATH's, else the newest under Program Files.
$escript = $null
if ($env:BEAM_ERLANG) {
    foreach ($c in (Join-Path $env:BEAM_ERLANG 'bin\escript.exe'), (Join-Path $env:BEAM_ERLANG 'escript.exe')) {
        if (Test-Path -LiteralPath $c) { $escript = $c; break }
    }
}
if (-not $escript) { $c = Get-Command escript.exe -ErrorAction SilentlyContinue; if ($c) { $escript = $c.Source } }
if (-not $escript) {
    $escript = @(Get-ChildItem -Path "$env:ProgramFiles\Erlang OTP\bin\escript.exe", "$env:ProgramFiles\erl*\bin\escript.exe" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 | ForEach-Object { $_.FullName })[0]
}
if (-not $escript) {
    [Console]::Error.WriteLine('processes: escript not found: BEAM_DIST is read with Erlang/OTP 25 or later (BEAM_ERLANG, where Erlang is, or escript.exe on the PATH)')
    exit 1
}

# A home of this run's own: Erlang writes a cookie file into its home when
# it has none, and never into Vigil's.
$home_ = Join-Path ([System.IO.Path]::GetTempPath()) ('vigil-beam.' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $home_)
$code = 1
try {
    $env:HOME = $home_; $env:USERPROFILE = $home_
    $env:HOMEDRIVE = $home_.Substring(0, 2); $env:HOMEPATH = $home_.Substring(2)
    & $escript (Join-Path $PSScriptRoot '_beam.escript') processes
    $code = $LASTEXITCODE
}
finally {
    Remove-Item -LiteralPath $home_ -Recurse -Force -ErrorAction SilentlyContinue
}
exit $code
