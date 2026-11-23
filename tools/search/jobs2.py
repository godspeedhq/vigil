# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
"""The elasticsearch and opensearch packs' jobs, continued: shards and
allocation (tools/search/jobs.py says how they are written)."""
from jobs import job, M, JOBS

# ---------------------------------------------------------------- shards
job(job='shards', metric='shards', when='run_every   = 1m', runtime='50s',
    title="the shards of a cluster, and why one is unassigned",
    what="Reports every shard by state (started, relocating, initializing, unassigned, primaries and "
         "replicas apart), the largest shards (by size and by documents, against the limits @P@ advises), "
         "each node's share, and each unassigned shard, primaries first, with why and since when. For the "
         "first of them, it asks @P@ to explain (_cluster/allocation/explain) and reports the reason it "
         "gives. Then the shard recoveries in progress, and how far each has come.",
    metrics=M(('up', '1 when @P@ answers, else 0'),
              ('shards', 'shards, primaries and replicas'),
              ('primaries', 'of those, primaries'),
              ('replicas', 'replicas'),
              ('started', 'shards started'),
              ('relocating', 'shards moving to another node'),
              ('initializing', 'shards being created or recovered'),
              ('unassigned', 'shards on no node'),
              ('unassigned_primaries', 'of those, primaries: their data is unreachable'),
              ('unassigned_replicas', 'replicas'),
              ('largest_shard_bytes', 'the largest shard'),
              ('largest_shard_docs', 'the most documents in a shard'),
              ('shards_over_50gb', 'shards larger than 50 GB, the most @P@ advises'),
              ('shards_over_200m_docs', 'shards of more than 200 million documents, the most @P@ advises'),
              ('node_shards', 'shards on a node, tagged node=<its name>'),
              ('unassigned_seconds', 'how long a shard has been unassigned, tagged index=<it>, shard=<its number>, '
                                     'prirep=<p or r> and reason=<why @P@ unassigned it>'),
              ('unassigned_not_shown', 'unassigned shards past the first 100, left out'),
              ('explained', "always 1, for the first unassigned shard: @P@'s explanation, tagged index, shard, "
                            "prirep, can_allocate=<no, yes, throttled, awaiting_info...>, decider=<what refused it> "
                            "and why=<its words>"),
              ('recoveries', 'shard recoveries in progress'),
              ('recovery_pct', 'how far one has come, in bytes, tagged index, shard, type=<why it recovers> '
                               'and stage=<where it is>'),
              ('recovery_ms', 'how long it has run, tagged the same'),
              ('recoveries_not_shown', 'recoveries past the first 50, left out')),
    healthy="unassigned 0; relocating and initializing 0 most of the time; shards_over_50gb 0.",
    watch="unassigned_replicas above 0 for minutes: a node gone, or replicas the cluster cannot place "
          "(explained says why); recoveries running for long; shards_over_50gb above 0: split the index, "
          "or roll it over sooner.",
    act="unassigned_primaries above 0: data unreachable; explained says why (a node gone, a disk full, a "
        "filter no node matches, a corrupt shard).",
    sh=r'''first
need '/_cat/shards?format=json&bytes=b&h=index,shard,prirep,state,unassigned.reason,unassigned.at,node,store,docs'
cp "$work/body" "$work/shards"
jq -r --argjson now "$now" "$jqlib"'
    map(.store |= n | .docs |= n) |
    "metric shards \(length)",
    "metric primaries \([.[] | select(.prirep == "p")] | length)",
    "metric replicas \([.[] | select(.prirep == "r")] | length)",
    "metric started \([.[] | select(.state == "STARTED")] | length)",
    "metric relocating \([.[] | select(.state == "RELOCATING")] | length)",
    "metric initializing \([.[] | select(.state == "INITIALIZING")] | length)",
    "metric unassigned \([.[] | select(.state == "UNASSIGNED")] | length)",
    "metric unassigned_primaries \([.[] | select(.state == "UNASSIGNED" and .prirep == "p")] | length)",
    "metric unassigned_replicas \([.[] | select(.state == "UNASSIGNED" and .prirep == "r")] | length)",
    "metric largest_shard_bytes \([.[].store] | max // 0)",
    "metric largest_shard_docs \([.[].docs] | max // 0)",
    "metric shards_over_50gb \([.[] | select(.store > 53687091200)] | length)",
    "metric shards_over_200m_docs \([.[] | select(.docs > 200000000)] | length)",
    ([.[] | select(.node != null and .node != "")] | group_by(.node)[] | "metric node_shards \(length) node=\(.[0].node | tag)"),
    ([.[] | select(.state == "UNASSIGNED") | . + {at: (.["unassigned.at"] | epoch)}]
        | sort_by(.prirep != "p", .at, .index, (.shard | n)) |
        (.[0:100][] | "metric unassigned_seconds \(if .at then ($now - .at | floor | if . < 0 then 0 else . end) else 0 end) index=\(.index | tag) shard=\(.shard | tag) prirep=\(.prirep | tag) reason=\(.["unassigned.reason"] | tag)"),
        "metric unassigned_not_shown \([length - 100, 0] | max)")
' "$work/body" || exit 1
# The first unassigned shard, primaries first: @P@'s own explanation.
jq -c '[.[] | select(.state == "UNASSIGNED")] | sort_by(.prirep != "p", .index, (.shard | tonumber)) | .[0] // empty | {index, shard: (.shard | tonumber), primary: (.prirep == "p")}' "$work/shards" > "$work/explain" || exit 1
if [ -s "$work/explain" ]; then
    get '/_cluster/allocation/explain?filter_path=index,shard,primary,can_allocate,allocate_explanation,node_allocation_decisions.node_decision,node_allocation_decisions.deciders' "$work/explain"
    rc=$?
    case $rc in
        0) jq -r "$jqlib"'
            ([.node_allocation_decisions[]?.deciders[]? | select(.decision == "NO" or .decision == "THROTTLE")][0]) as $d |
            "metric explained 1 index=\(.index | tag) shard=\(.shard | tag) prirep=\(if .primary then "p" else "r" end) can_allocate=\(.can_allocate | tag) decider=\($d.decider // "none" | tag) why=\(($d.explanation // .allocate_explanation // "") | tag)"
        ' "$work/body" || exit 1 ;;
        3) ;;
        *) why "$rc" '/_cluster/allocation/explain' ;;
    esac
fi
need '/_cat/recovery?format=json&active_only=true&bytes=b&time=ms&h=index,shard,type,stage,source_node,target_node,bytes_percent,time'
jq -r "$jqlib"'
    "metric recoveries \(length)",
    (sort_by(-(.time | n)) | .[0:50][] | "index=\(.index | tag) shard=\(.shard | tag) type=\(.type | tag) stage=\(.stage | tag)" as $t |
        "metric recovery_pct \(.bytes_percent | n) \($t)",
        "metric recovery_ms \(.time | n) \($t)"),
    "metric recoveries_not_shown \([length - 50, 0] | max)"
' "$work/body" || exit 1
exit 0
''',
    ps=r'''Read-First
$all = @(Need-Page '/_cat/shards?format=json&bytes=b&h=index,shard,prirep,state,unassigned.reason,unassigned.at,node,store,docs')
M 'shards' $all.Count
M 'primaries' (@($all | Where-Object { $_.prirep -eq 'p' }).Count)
M 'replicas' (@($all | Where-Object { $_.prirep -eq 'r' }).Count)
M 'started' (@($all | Where-Object { $_.state -eq 'STARTED' }).Count)
M 'relocating' (@($all | Where-Object { $_.state -eq 'RELOCATING' }).Count)
M 'initializing' (@($all | Where-Object { $_.state -eq 'INITIALIZING' }).Count)
$un = @($all | Where-Object { $_.state -eq 'UNASSIGNED' })
M 'unassigned' $un.Count
M 'unassigned_primaries' (@($un | Where-Object { $_.prirep -eq 'p' }).Count)
M 'unassigned_replicas' (@($un | Where-Object { $_.prirep -eq 'r' }).Count)
$big = 0; $most = 0
foreach ($x in $all) { if ((N $x.store) -gt $big) { $big = N $x.store }; if ((N $x.docs) -gt $most) { $most = N $x.docs } }
M 'largest_shard_bytes' $big
M 'largest_shard_docs' $most
M 'shards_over_50gb' (@($all | Where-Object { (N $_.store) -gt 53687091200 }).Count)
M 'shards_over_200m_docs' (@($all | Where-Object { (N $_.docs) -gt 200000000 }).Count)
foreach ($g in @($all | Where-Object { $_.node } | Group-Object { [string]$_.node } | Sort-Object Name)) { M 'node_shards' $g.Count "node=$(Safe $g.Name)" }
$uns = @($un | ForEach-Object { $_ | Add-Member -NotePropertyName at -NotePropertyValue (Epoch $_.'unassigned.at') -Force; $_ } |
    Sort-Object @{ Expression = { $_.prirep -ne 'p' } }, @{ Expression = { $_.at } }, @{ Expression = { [string]$_.index } }, @{ Expression = { N $_.shard } })
foreach ($x in @($uns | Select-Object -First 100)) {
    $s = if ($x.at) { [Math]::Max([Math]::Floor($script:Now - $x.at), 0) } else { 0 }
    M 'unassigned_seconds' $s "index=$(Safe $x.index) shard=$(Safe $x.shard) prirep=$(Safe $x.prirep) reason=$(Safe $x.'unassigned.reason')"
}
M 'unassigned_not_shown' ([Math]::Max($uns.Count - 100, 0))
# The first unassigned shard, primaries first: @P@'s own explanation.
$first = @($un | Sort-Object @{ Expression = { $_.prirep -ne 'p' } }, @{ Expression = { [string]$_.index } }, @{ Expression = { N $_.shard } }) | Select-Object -First 1
if ($first) {
    $req = '{"index":"' + ([string]$first.index -replace '["\\]', '') + '","shard":' + [int](N $first.shard) + ',"primary":' + $(if ($first.prirep -eq 'p') { 'true' } else { 'false' }) + '}'
    $p = Get-Page '/_cluster/allocation/explain?filter_path=index,shard,primary,can_allocate,allocate_explanation,node_allocation_decisions.node_decision,node_allocation_decisions.deciders' $req
    if ($p.State -eq 'ok') {
        $e = $p.Data
        $d = @(foreach ($nd in @($e.node_allocation_decisions)) { foreach ($dc in @($nd.deciders)) { if ($dc.decision -in 'NO', 'THROTTLE') { $dc } } }) | Select-Object -First 1
        $dec = if ($d) { $d.decider } else { 'none' }
        $why = if ($d) { $d.explanation } elseif ($e.allocate_explanation) { $e.allocate_explanation } else { '' }
        Write-Output "metric explained 1 index=$(Safe $e.index) shard=$(Safe $e.shard) prirep=$(if ($e.primary) { 'p' } else { 'r' }) can_allocate=$(Safe $e.can_allocate) decider=$(Safe $dec) why=$(Safe $why)"
    } elseif ($p.State -ne 'unsupported') { Stop-Why $p.State '/_cluster/allocation/explain' }
}
$rec = @(Need-Page '/_cat/recovery?format=json&active_only=true&bytes=b&time=ms&h=index,shard,type,stage,source_node,target_node,bytes_percent,time')
M 'recoveries' $rec.Count
foreach ($x in @($rec | Sort-Object @{ Expression = { N $_.time }; Descending = $true } | Select-Object -First 50)) {
    $t = "index=$(Safe $x.index) shard=$(Safe $x.shard) type=$(Safe $x.type) stage=$(Safe $x.stage)"
    M 'recovery_pct' $x.bytes_percent $t
    M 'recovery_ms' $x.time $t
}
M 'recoveries_not_shown' ([Math]::Max($rec.Count - 50, 0))
exit 0
''')

# ---------------------------------------------------------------- allocation
ALLOC_SETTINGS = ('/_cluster/settings?include_defaults=true&filter_path=*.cluster.routing.allocation.disk.watermark,'
                  '*.cluster.routing.allocation.disk.threshold_enabled,*.cluster.routing.allocation.enable,'
                  '*.cluster.routing.rebalance.enable,*.cluster.max_shards_per_node,'
                  '*.cluster.routing.allocation.exclude')
job(job='allocation', metric='allocation', when='run_every   = 1m', runtime='50s',
    title="where a cluster may put its shards: disks, watermarks and settings",
    what="Reports each data node's disk as @P@ weighs it for shards: its shards, the bytes its indices "
         "take, its disk used, free and total, and which disk watermark it is past (low: no new shards "
         "come to it; high: shards move off it; flood stage: its indices take no more writes), from the "
         "cluster's own watermarks and headroom. Then the settings that stop shards moving, which are "
         "often left behind after maintenance: allocation and rebalancing turned off, nodes excluded, "
         "the disk check off, and the cluster's shard limit against the shards it has.",
    metrics=M(('up', '1 when @P@ answers, else 0'),
              ('shards', "a node's shards, tagged node=<its name>"),
              ('undesired_shards', "of those, shards the balancer wants elsewhere (Elasticsearch 8.6 and later)"),
              ('disk_indices_bytes', "the bytes its indices take"),
              ('disk_used_bytes', 'its disk used, by anything'),
              ('disk_free_bytes', 'its disk free'),
              ('disk_total_bytes', 'its disk size'),
              ('disk_used_pct', 'its disk used, as @P@ counts it'),
              ('watermark', 'the disk watermark it is past: 0 none, 1 low, 2 high, 3 flood stage; tagged the same'),
              ('nodes_over_low', 'nodes past the low watermark: no new shards come to them'),
              ('nodes_over_high', 'past the high watermark: shards move off them'),
              ('nodes_over_flood', 'past the flood stage: their indices take no more writes'),
              ('watermark_pct', 'a watermark set as a percentage of the disk used, tagged level=<low, high or flood_stage>'),
              ('watermark_free_bytes', 'a watermark set as free space, tagged the same'),
              ('disk_threshold_enabled', '1 when @P@ weighs disks at all (the default)'),
              ('allocation_enabled', '1 when shards may be allocated (cluster.routing.allocation.enable all), '
                                     'tagged setting=<all, primaries, new_primaries or none>'),
              ('rebalance_enabled', '1 when shards may be rebalanced (cluster.routing.rebalance.enable all), tagged setting=<it>'),
              ('exclusions', 'allocation filters excluding nodes (cluster.routing.allocation.exclude)'),
              ('exclusion', 'always 1, for each, tagged attribute=<_name, _ip, _host or yours> and value=<what is excluded>'),
              ('max_shards_per_node', "the cluster's limit of open shards a data node"),
              ('shards_capacity_pct', "the cluster's shards, as a percentage of the limit for its data nodes: "
                                      "at 100, no index can be created"),
              ('nodes_not_shown', 'nodes past the first 100, by name, left out')),
    healthy="watermark 0 on every node; allocation_enabled and rebalance_enabled 1; exclusions 0; "
            "shards_capacity_pct below 80.",
    watch="nodes_over_low above 0: that node takes no new shards; exclusions above 0 after maintenance; "
          "undesired_shards staying above 0.",
    act="nodes_over_high above 0: shards moving off a full disk; nodes_over_flood above 0: writes to its "
        "indices fail; allocation_enabled 0 left after a restart: replicas stay unassigned; "
        "shards_capacity_pct near 100: new indices fail.",
    sh=r'''first
need '/_cat/allocation?format=json&bytes=b'
cp "$work/body" "$work/alloc"
need '@ALLOC_SETTINGS@'
jq -r --slurpfile al "$work/alloc" "$jqlib"'
    def bytes: ascii_downcase | capture("^(?<n>[0-9.]+)\\s*(?<u>[a-z]*)$") as $c |
        ($c.n | tonumber) * ({"": 1, "b": 1, "k": 1024, "kb": 1024, "m": 1048576, "mb": 1048576, "g": 1073741824, "gb": 1073741824,
            "t": 1099511627776, "tb": 1099511627776, "p": 1125899906842624, "pb": 1125899906842624}[$c.u] // 1);
    def wm: if . == null then null elif test("%$") then {pct: (rtrimstr("%") | tonumber)}
        elif test("^[0-9.]+$") then {pct: (tonumber * 100)} else {free: bytes} end;
    def at(p): (.transient | try getpath(p) catch null) // (.persistent | try getpath(p) catch null);
    def eff(p): at(p) // (.defaults | try getpath(p) catch null);
    def needfree(total): . as $x | if $x.w == null then null elif $x.w.pct != null then
        (total * (100 - $x.w.pct) / 100) as $f | (if $x.h != null and $x.h >= 0 then [$f, $x.h] | min else $f end) else $x.w.free end;
    ["cluster", "routing", "allocation", "disk", "watermark"] as $w |
    . as $s |
    # Each level: its watermark, and the headroom that caps it (set, or the
    # default when the watermark itself is not set).
    [["low", "high", "flood_stage"][] | . as $l | {level: $l, w: ($s | eff($w + [$l]) | wm),
        h: ((($s | at($w + [$l + ".max_headroom"])) // (if ($s | at($w + [$l])) == null then ($s.defaults | try getpath($w + [$l + ".max_headroom"]) catch null) else null end))
            | if . == null or . == "-1" then null else bytes end)}] as $lv |
    (($s | eff(["cluster", "routing", "allocation", "disk", "threshold_enabled"])) // "true" | tostring) as $on |
    [$al[0][] | select(.node != "UNASSIGNED" and .["disk.total"] != null)] | sort_by(.node) | . as $nodes |
    [$nodes[] | (.["disk.total"] | n) as $tot | (.["disk.avail"] | n) as $free |
        . + {level: (if $on != "true" then 0 else ([$lv[] | needfree($tot)] as $nf |
            if $nf[2] != null and $free < $nf[2] then 3 elif $nf[1] != null and $free < $nf[1] then 2 elif $nf[0] != null and $free < $nf[0] then 1 else 0 end) end)}] |
    (.[0:100][] | "node=\(.node | tag)" as $t |
        "metric shards \(.shards | n) \($t)",
        (if .["shards.undesired"] != null then "metric undesired_shards \(.["shards.undesired"] | n) \($t)" else empty end),
        "metric disk_indices_bytes \(.["disk.indices"] | n) \($t)",
        "metric disk_used_bytes \(.["disk.used"] | n) \($t)",
        "metric disk_free_bytes \(.["disk.avail"] | n) \($t)",
        "metric disk_total_bytes \(.["disk.total"] | n) \($t)",
        "metric disk_used_pct \(.["disk.percent"] | n) \($t)",
        "metric watermark \(.level) \($t)"),
    "metric nodes_over_low \([.[] | select(.level >= 1)] | length)",
    "metric nodes_over_high \([.[] | select(.level >= 2)] | length)",
    "metric nodes_over_flood \([.[] | select(.level >= 3)] | length)",
    ($lv[] | if .w.pct != null then "metric watermark_pct \(.w.pct | r2) level=\(.level)" elif .w.free != null then "metric watermark_free_bytes \(.w.free | floor) level=\(.level)" else empty end),
    "metric disk_threshold_enabled \(if $on == "true" then 1 else 0 end)",
    (($s | eff(["cluster", "routing", "allocation", "enable"])) // "all" | "metric allocation_enabled \(if . == "all" then 1 else 0 end) setting=\(tag)"),
    (($s | eff(["cluster", "routing", "rebalance", "enable"])) // "all" | "metric rebalance_enabled \(if . == "all" then 1 else 0 end) setting=\(tag)"),
    ([($s | at(["cluster", "routing", "allocation", "exclude"])) // {} | to_entries[] | select(.value != null and .value != "")] |
        "metric exclusions \(length)",
        (.[] | "metric exclusion 1 attribute=\(.key | tag) value=\(.value | tag)")),
    ((($s | eff(["cluster", "max_shards_per_node"])) // "1000" | n) as $max |
        "metric max_shards_per_node \($max)",
        "metric shards_capacity_pct \(pct([$al[0][].shards | n] | add // 0; $max * ($nodes | length)))"),
    "metric nodes_not_shown \([($nodes | length) - 100, 0] | max)"
' "$work/body" || exit 1
exit 0
''',
    ps=r'''Read-First
$al = @(Need-Page '/_cat/allocation?format=json&bytes=b')
$s = Need-Page '@ALLOC_SETTINGS@'
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
''')
JOBS[-1]['sh'] = JOBS[-1]['sh'].replace('@ALLOC_SETTINGS@', ALLOC_SETTINGS)
JOBS[-1]['ps'] = JOBS[-1]['ps'].replace('@ALLOC_SETTINGS@', ALLOC_SETTINGS)
