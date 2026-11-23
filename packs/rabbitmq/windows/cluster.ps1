#Requires -Version 5.1

<#
.SYNOPSIS
    cluster.ps1 - each RabbitMQ node's links to the others, and the cluster's virtual hosts, exchanges and bindings
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reads each node's Prometheus pages (rabbitmq_prometheus, port 15692), from RABBITMQ_TARGETS
    (<name>=<address> separated by ;): its
    Erlang distribution links to the other nodes (/metrics), and the
    cluster's virtual hosts, exchanges and bindings as this node sees them
    (/metrics/detailed). A node alone has no peers.

    Metrics:
      nodes                the nodes named in RABBITMQ_TARGETS
      up                   1 when the node's page answers, else 0, tagged
                           node=<its name>
      peers                the nodes it is linked to
      unreachable_peers    cluster members it cannot reach
      peer_up              1 when the link to a peer is up, 0 while it is
                           still being set up, tagged node=<its name> and
                           peer=<the peer's node name>
      peer_sent_bytes      bytes sent to that peer (a running total)
      peer_received_bytes  bytes received from it (a running total)
      peer_queue_bytes     bytes waiting to go to it
      vhosts               the virtual hosts
      vhosts_down          of those, not running on this node
      vhost_up             1 when a virtual host runs on this node, else 0,
                           tagged node=<its name> and vhost=<its name>
      exchanges            the exchanges, every virtual host
      bindings             the bindings from them
      peers_not_shown      past 100 peers, how many were left out
      vhosts_not_shown     past 100 virtual hosts, how many were left out

    Example output:
      metric nodes 1
      metric up 1 node=rabbit1

    Reading the results (starting points: tune them to the cluster):
      Healthy  peers one fewer than the cluster's nodes, every peer_up 1;
               unreachable_peers 0; vhosts_down 0; peer_queue_bytes near 0.
      Watch    peer_queue_bytes above 0 run after run: the link to that
               peer is slow or saturated; exchanges or bindings climbing
               without end: an application declaring them per message.
      Act      unreachable_peers above 0, or a peer missing: a node is down
               or cut off, and quorum queues there may have lost their
               majority; vhosts_down above 0: a virtual host failed to
               start here, and its clients are refused.

    Requires: bash, and the rabbitmq_prometheus plugin (on by default)
    Exit code: 0 on success, nodes up or down; 1 if a setting is wrong, or a page answers but is not RabbitMQ's
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$inv = [Globalization.CultureInfo]::InvariantCulture
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$targets = @(([string]$env:RABBITMQ_TARGETS) -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
Write-Output "metric nodes $($targets.Count)"
$code = 0

# Get-Page <url>: the page's lines; $null when nothing answers (a reading);
# 'error' when it answers wrong (a setting to fix), said on stderr.
function Get-Page([string]$url) {
    try { return @(([string](Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30).Content) -split "`n" | ForEach-Object { $_.TrimEnd("`r") }) }
    catch {
        if ($_.Exception.Response) { [Console]::Error.WriteLine("cluster: $url did not give a page: $($_.Exception.Message)"); return 'error' }
        return $null
    }
}
# A label's value in a Prometheus line, or ''.
function Label([string]$line, [string]$key) {
    if ($line -match ('[{,]' + $key + '="([^"]*)"')) { return $Matches[1] }
    return ''
}
# A tag's value: no spaces, quotes or control characters, never empty.
function Safe([string]$s) {
    $s = $s -replace '[^A-Za-z0-9@._:/+-]', '_'
    if (-not $s) { return 'none' }
    if ($s.Length -gt 120) { return $s.Substring(0, 120) }
    return $s
}
# The number as Vigil reads it.
function Num([double]$v, [string]$f = '0') { return $v.ToString($f, $inv) }
# Each target: name, address, and the page at $path, or why not.
function Read-Target([string]$entry, [string]$path) {
    $i = $entry.IndexOf('=')
    if ($i -lt 1 -or $i -eq $entry.Length - 1) {
        [Console]::Error.WriteLine("cluster: RABBITMQ_TARGETS: '$entry' is not <name>=<address>, as in rabbit1=http://127.0.0.1:15692")
        exit 1
    }
    $name = $entry.Substring(0, $i).Trim() -replace '[^A-Za-z0-9@._:-]', '_'
    $url = $entry.Substring($i + 1).Trim().TrimEnd('/')
    $page = Get-Page ($url + $path)
    if ($null -eq $page) { Write-Output "metric up 0 node=$name"; return $null }
    if ($page -is [string] -and $page -eq 'error') { Write-Output "metric up 0 node=$name"; $script:code = 1; return $null }
    if (-not ($page | Where-Object { $_.StartsWith('rabbitmq_build_info') })) {
        Write-Output "metric up 0 node=$name"
        [Console]::Error.WriteLine("cluster: ${name}: $url$path answers, but is not RabbitMQ's Prometheus page")
        $script:code = 1
        return $null
    }
    Write-Output "metric up 1 node=$name"
    return @{ Name = $name; Url = $url; Page = $page }
}
# Sums by metric name (labels dropped), and which names were seen.
function Get-Sums($page) {
    $s = @{}
    foreach ($l in $page) {
        if (-not $l -or $l.StartsWith('#')) { continue }
        $p = $l -split '\s+'
        if ($p.Count -lt 2) { continue }
        $b = $p[0] -replace '\{.*$', ''
        $v = 0.0
        if (-not [double]::TryParse($p[1], [Globalization.NumberStyles]::Float, $inv, [ref]$v)) { continue }
        if ($s.ContainsKey($b)) { $s[$b] += $v } else { $s[$b] = $v }
    }
    return $s
}

foreach ($entry in $targets) {
    $t = Read-Target $entry '/metrics'
    if ($t -isnot [hashtable]) { $t | Where-Object { $_ -is [string] } | ForEach-Object { Write-Output $_ }; continue }
    $tag = "node=$($t.Name)"
    $detailed = Get-Page ($t.Url + '/metrics/detailed?family=vhost_status&family=exchange_names&family=exchange_bindings')
    if ($null -eq $detailed -or ($detailed -is [string])) { $detailed = @() }
    $peers = [ordered]@{}; $unreach = $null; $vh = [ordered]@{}; $ex = 0; $bi = 0.0; $hasBi = $false
    foreach ($l in ($t.Page + $detailed)) {
        if (-not $l -or $l.StartsWith('#')) { continue }
        $p = $l -split '\s+'
        if ($p.Count -lt 2) { continue }
        $base = $p[0] -replace '\{.*$', ''
        $v = 0.0; [void][double]::TryParse($p[1], [Globalization.NumberStyles]::Float, $inv, [ref]$v)
        if ($base.StartsWith('erlang_vm_dist_')) {
            $peer = Label $p[0] 'peer'
            if (-not $peer) { continue }
            if (-not $peers.Contains($peer)) { $peers[$peer] = @{ state = 0; queue = 0.0 } }
            switch ($base) {
                'erlang_vm_dist_node_state' { $peers[$peer].state = $v }
                'erlang_vm_dist_send_bytes' { $peers[$peer].sent = $v }
                'erlang_vm_dist_recv_bytes' { $peers[$peer].recv = $v }
                'erlang_vm_dist_node_queue_size_bytes' { $peers[$peer].queue += $v }
                'erlang_vm_dist_port_queue_size_bytes' { $peers[$peer].queue += $v }
            }
        }
        elseif ($base -eq 'rabbitmq_unreachable_cluster_peers_count') { $unreach = $v }
        elseif ($base -eq 'rabbitmq_cluster_vhost_status') { $vh[(Label $p[0] 'vhost')] = $v }
        elseif ($base -eq 'rabbitmq_cluster_exchange_name') { $ex++ }
        elseif ($base -eq 'rabbitmq_cluster_exchange_bindings') { $bi += $v; $hasBi = $true }
    }
    Write-Output "metric peers $($peers.Count) $tag"
    if ($null -ne $unreach) { Write-Output "metric unreachable_peers $(Num $unreach) $tag" }
    foreach ($peer in @($peers.Keys | Select-Object -First 100)) {
        $pt = "$tag peer=$(Safe $peer)"; $x = $peers[$peer]
        Write-Output "metric peer_up $(if ($x.state -eq 3) { 1 } else { 0 }) $pt"
        if ($x.ContainsKey('sent')) { Write-Output "metric peer_sent_bytes $(Num $x.sent) $pt" }
        if ($x.ContainsKey('recv')) { Write-Output "metric peer_received_bytes $(Num $x.recv) $pt" }
        Write-Output "metric peer_queue_bytes $(Num $x.queue) $pt"
    }
    Write-Output "metric peers_not_shown $([Math]::Max(0, $peers.Count - 100)) $tag"
    if ($vh.Count -gt 0) {
        Write-Output "metric vhosts $($vh.Count) $tag"
        Write-Output "metric vhosts_down $(@($vh.Values | Where-Object { $_ -ne 1 }).Count) $tag"
        foreach ($k in @($vh.Keys | Select-Object -First 100)) { Write-Output "metric vhost_up $(if ($vh[$k] -eq 1) { 1 } else { 0 }) $tag vhost=$(Safe $k)" }
        Write-Output "metric vhosts_not_shown $([Math]::Max(0, $vh.Count - 100)) $tag"
    }
    if ($ex -gt 0) { Write-Output "metric exchanges $ex $tag" }
    if ($hasBi) { Write-Output "metric bindings $(Num $bi) $tag" }
}
exit $code
