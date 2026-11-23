#Requires -Version 5.1

<#
.SYNOPSIS
    dist.ps1 - each Erlang VM's peers: the nodes it is connected to
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reads the connections of each node in BEAM_DIST (<name>=<node> separated
    by ;) with its cookie (BEAM_COOKIE, a secret), by _beam.escript beside
    this script, with Erlang's escript (BEAM_ERLANG, where Erlang is, else the
    PATH's): its peers in the cluster, the hidden ones (tools; Vigil's own
    leaves no trace), and the bytes waiting to go to each.

    WARNING: a node's cookie lets whoever holds it run anything on that node.
    This pack never changes anything: it only reads, and _beam.escript lists
    every call it makes. Give Vigil the cookie only if you accept that.

    Metrics:
      nodes             the nodes named in BEAM_DIST
      up                1 when the node answers, else 0, tagged node=<its
                        name> and source=dist
      peers             the nodes it is connected to, as a cluster
      hidden_peers      hidden nodes connected to it (remote shells, tools)
      peer              always 1, tagged node=<its name>, source=dist,
                        peer=<the peer's node> and hidden=<true or false>
      peer_queue_bytes  bytes waiting to be sent to that peer, tagged the
                        same (TCP distribution; not over TLS)
      peers_not_shown   past the first 100 peers, how many were left out
      busy_limit_bytes  the queue at which a peer's sender is made to wait
                        (+zdbbl)

    Example output:
      metric nodes 1
      metric up 1 node=tw source=dist
      metric peers 0 node=tw source=dist
      metric hidden_peers 0 node=tw source=dist
      metric peers_not_shown 0 node=tw source=dist
      metric busy_limit_bytes 1048576 node=tw source=dist

    Reading the results (starting points: tune them to the cluster):
      Healthy  peers as many as the cluster's other nodes; peer_queue_bytes
               near 0.
      Watch    hidden_peers you do not expect: someone has a remote shell
               on the node, or a tool holds the cookie.
      Act      peers lower than the cluster's other nodes: a node is down or
               cut off (a partition); peer_queue_bytes near busy_limit_bytes:
               the link to that peer is the bottleneck, and its senders wait.

    Requires: Windows PowerShell 5.1 or PowerShell 7; Erlang/OTP 25 or later (escript.exe)
    Exit code: 0 on success, nodes up or down, or none named; 1 if escript.exe is
      missing, BEAM_DIST or BEAM_COOKIE is wrong, or a node refused the cookie
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
    [Console]::Error.WriteLine('dist: escript not found: BEAM_DIST is read with Erlang/OTP 25 or later (BEAM_ERLANG, where Erlang is, or escript.exe on the PATH)')
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
    & $escript (Join-Path $PSScriptRoot '_beam.escript') dist
    $code = $LASTEXITCODE
}
finally {
    Remove-Item -LiteralPath $home_ -Recurse -Force -ErrorAction SilentlyContinue
}
exit $code
