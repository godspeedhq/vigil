#Requires -Version 5.1

<#
.SYNOPSIS
    epmd.ps1 - the Erlang nodes epmd knows, on each machine named
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Asks epmd, the Erlang Port Mapper Daemon, which nodes it has: the
    names request of its protocol (what epmd -names sends), over TCP from
    PowerShell itself. It needs no cookie and changes nothing. The machines
    are in BEAM_EPMD, host or host:port separated by spaces or ;, set by
    the job; empty, this machine's (127.0.0.1:4369).

    Metrics:
        epmd_up          1 when epmd answers, else 0, tagged host=<host:port>
        nodes            the nodes it has, tagged host=<the same>
        node             always 1, tagged host=<the same>, name=<the
                         node's name> and port=<its distribution port>
        nodes_not_shown  past the first 100 nodes of a host, how many were
                         left out, tagged host=<the same>

    Example output:
      metric epmd_up 1 host=127.0.0.1:4369
      metric nodes 2 host=127.0.0.1:4369
      metric node 1 host=127.0.0.1:4369 name=rabbit port=25672
      metric node 1 host=127.0.0.1:4369 name=tw port=62893
      metric nodes_not_shown 0 host=127.0.0.1:4369

    Reading the results (starting points: tune them to the machine):
      Healthy  epmd_up 1; nodes as many as you run, each with its usual name.
      Watch    a node with a name you do not know: something else on the
               machine runs Erlang distribution (rabbitmqcli-... and
               vigil_... nodes come and go: tools connecting).
      Act      epmd_up 0 where nodes run: no node can find another, so a
               cluster cannot form again; a node you run missing from it:
               it stopped, or cannot register.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0 on success, epmd up or down; 1 if BEAM_EPMD is wrong
#>

$ErrorActionPreference = 'Stop'

$hosts = @(([string]$env:BEAM_EPMD) -split '[\s;,]+' | Where-Object { $_ })
if ($hosts.Count -eq 0) { $hosts = @('127.0.0.1') }

# epmd's names request: a length of 1 (two bytes) and 'n' (110). It
# answers its own port (four bytes), then a line a node: "name <name> at
# port <port>". Five seconds at most.
function Names([string]$h, [int]$port) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $connect = $client.ConnectAsync($h, $port)
        if (-not $connect.Wait(5000) -or -not $client.Connected) { return $null }
        $stream = $client.GetStream()
        $stream.ReadTimeout = 5000
        $stream.Write([byte[]](0, 1, 110), 0, 3)
        $buffer = New-Object System.IO.MemoryStream
        $chunk = New-Object byte[] 8192
        while (($n = $stream.Read($chunk, 0, $chunk.Length)) -gt 0) { $buffer.Write($chunk, 0, $n) }
        $bytes = $buffer.ToArray()
        if ($bytes.Length -lt 4) { return $null }
        [System.Text.Encoding]::ASCII.GetString($bytes, 4, $bytes.Length - 4)
    }
    catch { $null }
    finally { $client.Close() }
}

foreach ($h in $hosts) {
    if ($h -match '^\[(.+)\]:(\d+)$') { $hostName = $Matches[1]; $port = $Matches[2] }
    elseif ($h -match '^[^:]+:(\d+)$') { $hostName = $h.Substring(0, $h.LastIndexOf(':')); $port = $Matches[1] }
    elseif ($h -match '^[^:]+$' -or $h -match ':.*:') { $hostName = $h; $port = '4369' }
    else { [Console]::Error.WriteLine("epmd: BEAM_EPMD: '$h' is not host or host:port"); exit 1 }
    $tag = "host=${hostName}:$port"
    $text = Names $hostName ([int]$port)
    if ($null -eq $text) {
        Write-Output "metric epmd_up 0 $tag"
        continue
    }
    Write-Output "metric epmd_up 1 $tag"
    $found = @([regex]::Matches($text, '(?m)^name (\S+) at port (\d+)'))
    Write-Output "metric nodes $($found.Count) $tag"
    foreach ($m in ($found | Select-Object -First 100)) {
        $name = $m.Groups[1].Value -replace '[^A-Za-z0-9@._-]', '_'
        Write-Output "metric node 1 $tag name=$name port=$($m.Groups[2].Value)"
    }
    Write-Output "metric nodes_not_shown $([Math]::Max(0, $found.Count - 100)) $tag"
}
exit 0
