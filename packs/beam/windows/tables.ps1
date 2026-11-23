#Requires -Version 5.1

<#
.SYNOPSIS
    tables.ps1 - inside each Erlang VM: its ETS tables, the largest
.DESCRIPTION
    Reads every ETS table of each node in BEAM_DIST (<name>=<node> separated by
    ;) with its cookie (BEAM_COOKIE, a secret), by _beam.escript beside this
    script, with Erlang's escript (BEAM_ERLANG, where Erlang is, else the
    PATH's): its size and memory, and the process that owns it.

    WARNING: a node's cookie lets whoever holds it run anything on that node.
    This pack never changes anything: it only reads, and _beam.escript lists
    every call it makes. Give Vigil the cookie only if you accept that.

    Metrics:
      nodes               the nodes named in BEAM_DIST
      up                  1 when the node answers, else 0, tagged node=<its
                          name> and source=dist
      tables              its ETS tables
      objects             the objects in them all
      memory_bytes        the memory they all hold
      table_memory_bytes  memory one of the ten largest holds, tagged
                          node=<its name>, source=dist, table=<its name,
                          with (unnamed) when it is not a named table> and
                          owner=<the process that owns it>
      table_objects       objects one of the ten fullest holds, tagged the
                          same

    Example output:
      metric nodes 1
      metric up 1 node=n28 source=dist
      metric tables 21 node=n28 source=dist
      metric objects 2386 node=n28 source=dist
      metric memory_bytes 381616 node=n28 source=dist
      metric table_memory_bytes 105848 node=n28 source=dist table=code_names owner=code_server
      metric table_objects 1006 node=n28 source=dist table=code_names owner=code_server

    Reading the results (starting points: tune them to the node):
      Healthy  tables steady; the largest tables the same ones, at a size
               your data explains.
      Watch    one table_objects rising and never falling: a cache with no
               eviction, or entries never deleted.
      Act      memory_bytes a large share of beam.vm memory_bytes total and
               climbing: a table will take the VM's memory; tables rising
               run after run: tables made and never deleted (beam.vm ets_pct
               shows how near the limit).

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
    [Console]::Error.WriteLine('tables: escript not found: BEAM_DIST is read with Erlang/OTP 25 or later (BEAM_ERLANG, where Erlang is, or escript.exe on the PATH)')
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
    & $escript (Join-Path $PSScriptRoot '_beam.escript') tables
    $code = $LASTEXITCODE
}
finally {
    Remove-Item -LiteralPath $home_ -Recurse -Force -ErrorAction SilentlyContinue
}
exit $code
