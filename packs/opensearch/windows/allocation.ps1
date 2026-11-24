#Requires -Version 5.1

<#
.SYNOPSIS
    allocation.ps1 - where a cluster may put its shards: disks, watermarks and settings, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports each data node's disk as OpenSearch weighs it for shards: its
    shards, the bytes its indices take, its disk used, free and total, and which
    disk watermark it is past (low: no new shards come to it; high: shards move
    off it; flood stage: its indices take no more writes), from the cluster's
    own watermarks and headroom. Then the settings that stop shards moving,
    which are often left behind after maintenance: allocation and rebalancing
    turned off, nodes excluded, the disk check off, and the cluster's shard
    limit against the shards it has. It only reads: it changes nothing in the
    cluster.

    Reads OpenSearch at OPENSEARCH_URL (default https://localhost:9200), as
    OPENSEARCH_USER with the password in OPENSEARCH_PASSWORD (a secret). The
    login goes in a header made here, never on a command line.
    It speaks HTTP itself, with .NET: nothing to install. Over https, the
    certificate is checked against Windows' trusted CAs, or OPENSEARCH_CACERT, a
    CA file, and against the server's name. What the scripts share is in
    _opensearch.ps1, beside this one.

    Metrics:
      up                      1 when OpenSearch answers, else 0
      shards                  a node's shards, tagged node=<its name>
      undesired_shards        of those, shards the balancer wants elsewhere
                              (Elasticsearch 8.6 and later)
      disk_indices_bytes      the bytes its indices take
      disk_used_bytes         its disk used, by anything
      disk_free_bytes         its disk free
      disk_total_bytes        its disk size
      disk_used_pct           its disk used, as OpenSearch counts it
      watermark               the disk watermark it is past: 0 none, 1 low, 2
                              high, 3 flood stage; tagged the same
      nodes_over_low          nodes past the low watermark: no new shards come
                              to them
      nodes_over_high         past the high watermark: shards move off them
      nodes_over_flood        past the flood stage: their indices take no more
                              writes
      watermark_pct           a watermark set as a percentage of the disk used,
                              tagged level=<low, high or flood_stage>
      watermark_free_bytes    a watermark set as free space, tagged the same
      disk_threshold_enabled  1 when OpenSearch weighs disks at all (the
                              default)
      allocation_enabled      1 when shards may be allocated
                              (cluster.routing.allocation.enable all), tagged
                              setting=<all, primaries, new_primaries or none>
      rebalance_enabled       1 when shards may be rebalanced
                              (cluster.routing.rebalance.enable all), tagged
                              setting=<it>
      exclusions              allocation filters excluding nodes
                              (cluster.routing.allocation.exclude)
      exclusion               always 1, for each, tagged attribute=<_name, _ip,
                              _host or yours> and value=<what is excluded>
      max_shards_per_node     the cluster's limit of open shards a data node
      shards_capacity_pct     the cluster's shards, as a percentage of the limit
                              for its data nodes: at 100, no index can be
                              created
      nodes_not_shown         nodes past the first 100, by name, left out

    Example output (the rest are in the same form):
      metric up 1
      metric disk_used_pct 65 node=os310a
      metric watermark 2 node=os310a
      metric nodes_over_high 3
      metric allocation_enabled 0 setting=primaries
      metric exclusion 1 attribute=_name value=decommissioned-1
      metric shards_capacity_pct 100

    Reading the results (starting points: tune them to the cluster):
      Healthy  watermark 0 on every node; allocation_enabled and
               rebalance_enabled 1; exclusions 0; shards_capacity_pct below 80.
      Watch    nodes_over_low above 0: that node takes no new shards; exclusions
               above 0 after maintenance; undesired_shards staying above 0.
      Act      nodes_over_high above 0: shards moving off a full disk;
               nodes_over_flood above 0: writes to its indices fail;
               allocation_enabled 0 left after a restart: replicas stay
               unassigned; shards_capacity_pct near 100: new indices fail.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0 on success, OpenSearch up or down; 1 if a setting is wrong, the
      login is refused, this user may not read what the job needs, or the
      address is not OpenSearch
#>

$Job = 'allocation'
. (Join-Path $PSScriptRoot '_opensearch.ps1')

Read-First
$al = @(Need-Page '/_cat/allocation?format=json&bytes=b')
$s = Need-Page '/_cluster/settings?include_defaults=true&filter_path=*.cluster.routing.allocation.disk.watermark,*.cluster.routing.allocation.disk.threshold_enabled,*.cluster.routing.allocation.enable,*.cluster.routing.rebalance.enable,*.cluster.max_shards_per_node,*.cluster.routing.allocation.exclude'
function Get-Path($o, [string[]]$path) {
    foreach ($k in $path) {
        if ($null -eq $o -or $o -isnot [psobject] -or $o -is [string]) { return $null }
        $p = $o.PSObject.Properties[$k]
        if (-not $p) { return $null }
        $o = $p.Value
    }
    return $o
}
function At([string[]]$path) { $v = Get-Path $s.transient $path; if ($null -eq $v) { $v = Get-Path $s.persistent $path }; return $v }
function Eff([string[]]$path) { $v = At $path; if ($null -eq $v) { $v = Get-Path $s.defaults $path }; return $v }
function Bytes([string]$v) {
    if ($v.ToLowerInvariant() -notmatch '^([0-9.]+)\s*([a-z]*)$') { return [double]0 }
    $u = @{ '' = 1; 'b' = 1; 'k' = 1024; 'kb' = 1024; 'm' = 1048576; 'mb' = 1048576; 'g' = 1073741824; 'gb' = 1073741824; 't' = 1099511627776; 'tb' = 1099511627776; 'p' = 1125899906842624; 'pb' = 1125899906842624 }
    $f = $u[$Matches[2]]; if (-not $f) { $f = 1 }
    return (N $Matches[1]) * $f
}
function Wm($v) {
    if ($null -eq $v) { return $null }
    $v = [string]$v
    if ($v.EndsWith('%')) { return @{ pct = (N $v) } }
    if ($v -match '^[0-9.]+$') { return @{ pct = (N $v) * 100 } }
    return @{ free = (Bytes $v) }
}
$w = 'cluster', 'routing', 'allocation', 'disk', 'watermark'
$lv = @(foreach ($l in 'low', 'high', 'flood_stage') {
    $h = At ($w + "$l.max_headroom")
    if ($null -eq $h -and $null -eq (At ($w + $l))) { $h = Get-Path $s.defaults ($w + "$l.max_headroom") }
    $hb = if ($null -eq $h -or "$h" -eq '-1') { $null } else { Bytes $h }
    @{ level = $l; w = (Wm (Eff ($w + $l))); h = $hb }
})
function Need-Free($x, [double]$total) {
    if ($null -eq $x.w) { return $null }
    if ($x.w.ContainsKey('pct')) {
        $f = $total * (100 - $x.w.pct) / 100
        if ($null -ne $x.h -and $x.h -ge 0) { return [Math]::Min($f, $x.h) }
        return $f
    }
    return $x.w.free
}
$te = Eff ('cluster', 'routing', 'allocation', 'disk', 'threshold_enabled')
$on = if ($null -eq $te) { 'true' } else { ([string]$te).ToLowerInvariant() }
$nodes = @($al | Where-Object { $_.node -ne 'UNASSIGNED' -and $null -ne $_.'disk.total' } | Sort-Object { [string]$_.node })
$levels = @{}
foreach ($x in $nodes) {
    $tot = N $x.'disk.total'; $free = N $x.'disk.avail'
    $lvl = 0
    if ($on -eq 'true') {
        $nf = @($lv | ForEach-Object { Need-Free $_ $tot })
        if ($null -ne $nf[2] -and $free -lt $nf[2]) { $lvl = 3 } elseif ($null -ne $nf[1] -and $free -lt $nf[1]) { $lvl = 2 } elseif ($null -ne $nf[0] -and $free -lt $nf[0]) { $lvl = 1 }
    }
    $levels[[string]$x.node] = $lvl
}
foreach ($x in @($nodes | Select-Object -First 100)) {
    $t = "node=$(Safe $x.node)"
    M 'shards' $x.shards $t
    if ($null -ne $x.'shards.undesired') { M 'undesired_shards' $x.'shards.undesired' $t }
    M 'disk_indices_bytes' $x.'disk.indices' $t
    M 'disk_used_bytes' $x.'disk.used' $t
    M 'disk_free_bytes' $x.'disk.avail' $t
    M 'disk_total_bytes' $x.'disk.total' $t
    M 'disk_used_pct' $x.'disk.percent' $t
    M 'watermark' $levels[[string]$x.node] $t
}
M 'nodes_over_low' (@($levels.Values | Where-Object { $_ -ge 1 }).Count)
M 'nodes_over_high' (@($levels.Values | Where-Object { $_ -ge 2 }).Count)
M 'nodes_over_flood' (@($levels.Values | Where-Object { $_ -ge 3 }).Count)
foreach ($x in $lv) {
    if ($null -eq $x.w) { continue }
    if ($x.w.ContainsKey('pct')) { M 'watermark_pct' (R2 $x.w.pct) "level=$($x.level)" } else { M 'watermark_free_bytes' ([Math]::Floor($x.w.free)) "level=$($x.level)" }
}
M 'disk_threshold_enabled' $(if ($on -eq 'true') { 1 } else { 0 })
$ae = Eff ('cluster', 'routing', 'allocation', 'enable'); if ($null -eq $ae) { $ae = 'all' }
M 'allocation_enabled' $(if ($ae -eq 'all') { 1 } else { 0 }) "setting=$(Safe $ae)"
$re = Eff ('cluster', 'routing', 'rebalance', 'enable'); if ($null -eq $re) { $re = 'all' }
M 'rebalance_enabled' $(if ($re -eq 'all') { 1 } else { 0 }) "setting=$(Safe $re)"
$ex = @(Props (At ('cluster', 'routing', 'allocation', 'exclude')) | Where-Object { $null -ne $_.Value -and "$($_.Value)" -ne '' })
M 'exclusions' $ex.Count
foreach ($e in $ex) { Write-Output "metric exclusion 1 attribute=$(Safe $e.Name) value=$(Safe $e.Value)" }
$mx = Eff ('cluster', 'max_shards_per_node'); if ($null -eq $mx) { $mx = '1000' }
$max = N $mx
M 'max_shards_per_node' $max
M 'shards_capacity_pct' (Pct (($al | ForEach-Object { N $_.shards } | Measure-Object -Sum).Sum) ($max * $nodes.Count))
M 'nodes_not_shown' ([Math]::Max($nodes.Count - 100, 0))
exit 0
