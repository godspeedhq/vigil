# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
"""The nats pack's jobs (tools/obs/DESIGN.md): a NATS server and its
JetStream, from its monitoring port (/healthz, /varz, /connz, /routez and
/jsz). NATS says what is wrong with it in JSON, not in Prometheus' text, so
every job is code: jq on Linux and macOS, ConvertFrom-Json on Windows.

What a stream or a consumer holds is read only on the node that leads it:
each node of a cluster lists the streams it holds a replica of, and only the
leader's view of its replicas is current. So a cluster's streams are counted
once, by their leaders, and a backend sums them by stream."""
from jobs import job, code

PACK = dict(
    P='NATS', E='NATS', url='http://localhost:8222', version='1.0.0',
    description='NATS and JetStream: healthy, connections against the limit, slow consumers, the client with the '
                'most waiting; cluster routes and peers; JetStream storage and memory against their limits, API '
                'errors, the meta leader, streams with no leader, replicas behind, streams near their limits, and '
                'consumers behind (pending, waiting for acks, redelivered), each named',
    works='NATS Server 2.10 and later, alone or in a cluster, with or without JetStream (tested: 2.15.3, a cluster '
          'of three, and 2.14.10 alone)',
    head=['nats - a NATS server, from its monitoring port: is it healthy, how many',
          'clients and how close to its limit, which are too slow to keep up, are',
          'its cluster routes up, and for JetStream how full is it, does every',
          'stream have a leader, and which consumers are falling behind.'],
    needs=['its monitoring port, from this machine: -m 8222 (http_port: 8222 in its configuration); env = '
           'NATS_URL=... on each job where it is not http://localhost:8222',
           'jq, on Linux and macOS',
           "on each server of a cluster: each reports itself, and the streams and consumers it leads; for its CPU "
           "and memory: the base pack's processes job"])

READS = 'Reads @E@_URL (default @URL@), its monitoring port'

# What every job's jq shares: a tag's value, a time as seconds since 1970, a
# percentage, and a Go duration (211µs, 1.5ms, 2m3s) as milliseconds.
JQ_DEFS = r'''def t: tostring | gsub("[^A-Za-z0-9@._:/+-]"; "_") | .[0:120] | if . == "" then "none" else . end;
def ts: .[0:19] + "Z" | fromdateiso8601;
def pct(a; b): if b > 0 then (a * 10000 / b | round) / 100 else 0 end;
def ms: [scan("([0-9.]+)(h|ms|m|s|µs|us|ns)")]
    | map((.[0] | tonumber) * ({"h": 3600000, "m": 60000, "s": 1000, "ms": 1, "µs": 0.001, "us": 0.001, "ns": 0.000001}[.[1]]))
    | (add // 0) * 1000 | round / 1000;
'''

# The same in PowerShell. ConvertFrom-Json in PowerShell 7 makes a time a
# DateTime; in 5.1 it stays text.
PS_DEFS = r'''function Ts($s) {
    if ($s -is [DateTime]) { return ([DateTimeOffset]$s.ToUniversalTime()).ToUnixTimeSeconds() }
    return [DateTimeOffset]::Parse(([string]$s).Substring(0, 19) + 'Z', $script:Inv).ToUnixTimeSeconds()
}
function Pct($a, $b) { if ([double]$b -gt 0) { [Math]::Round([double]$a * 100 / [double]$b, 2, [MidpointRounding]::AwayFromZero) } else { 0 } }
function Ms($d) {
    $sum = 0.0
    $unit = @{ 'h' = 3600000.0; 'm' = 60000.0; 's' = 1000.0; 'ms' = 1.0; "$([char]0xB5)s" = 0.001; 'us' = 0.001; 'ns' = 0.000001 }
    foreach ($x in [regex]::Matches([string]$d, "([0-9.]+)(h|ms|m|s|$([char]0xB5)s|us|ns)")) {
        $sum += [double]::Parse($x.Groups[1].Value, $script:Inv) * $unit[$x.Groups[2].Value]
    }
    [Math]::Round($sum, 3, [MidpointRounding]::AwayFromZero)
}
function Num($v) { if ($null -eq $v) { 0 } else { $v } }
'''

# The first request, the same in every job: /varz, which answers whatever
# the state; then up.
VARZ_SH = r'''get '/varz' varz
case $? in
    0) echo "metric up 1" ;;
    2 | 5) echo "metric up 0"; exit 0 ;;
    3) echo "metric up 0"; echo "$job: $url/varz: no such page (HTTP 404): is @E@_URL its monitoring port (-m 8222)?" >&2; exit 0 ;;
    *) echo "metric up 0"; exit 1 ;;
esac
'''
VARZ_PS = r'''$r = Get-Answer '/varz'
switch ($r.State) {
    'ok' { Write-Output 'metric up 1' }
    'down' { Write-Output 'metric up 0'; exit 0 }
    'notready' { Write-Output 'metric up 0'; exit 0 }
    'missing' { Write-Output 'metric up 0'; [Console]::Error.WriteLine("${Job}: $($script:Url)/varz: no such page (HTTP 404): is @E@_URL its monitoring port (-m 8222)?"); exit 0 }
    default { Write-Output 'metric up 0'; [Console]::Error.WriteLine("${Job}: $($r.Why)"); exit 1 }
}
$v = $r.Body | ConvertFrom-Json
'''

STATUS_SH = VARZ_SH + r'''# /healthz answers 503 when the server is not ready: JetStream not current
# with its cluster, or not started.
get '/healthz' healthz
case $? in
    0) echo "metric healthy 1" ;;
    5) echo "metric healthy 0" ;;
esac
jq -r '@DEFS@
    "metric info 1 server=\(.server_name | t) version=\(.version | t) cluster=\(.cluster.name // "" | t) jetstream=\(if .jetstream.config then "on" else "off" end)",
    "metric uptime_seconds \((.now | ts) - (.start | ts))",
    "metric last_reload_seconds \((.now | ts) - (.config_load_time | ts))",
    "metric connections \(.connections)",
    "metric max_connections \(.max_connections)",
    "metric connections_pct \(pct(.connections; .max_connections))",
    "metric total_connections_count \(.total_connections)",
    "metric subscriptions \(.subscriptions)",
    "metric slow_consumers_count \(.slow_consumers)",
    (.slow_consumer_stats // empty |
        "metric slow_consumer_clients_count \(.clients)",
        "metric slow_consumer_routes_count \(.routes)",
        "metric slow_consumer_gateways_count \(.gateways)",
        "metric slow_consumer_leafs_count \(.leafs)"),
    "metric stale_connections_count \(.stale_connections // 0)",
    "metric in_msgs_count \(.in_msgs)",
    "metric out_msgs_count \(.out_msgs)",
    "metric in_bytes_count \(.in_bytes)",
    "metric out_bytes_count \(.out_bytes)"' "$work/varz"
# The client with the most bytes waiting to be sent to it: the next slow
# consumer, before the server cuts it off.
if get '/connz?sort=pending&limit=1' connz; then
    jq -r '@DEFS@
        (.connections // [])[0] |
        if . == null then "metric pending_bytes_max 0 client=none"
        else "metric pending_bytes_max \(.pending_bytes // 0) client=\(if (.name // "") != "" then .name else "\(.ip):\(.port)" end | t)" end' "$work/connz"
fi
'''.replace('@DEFS@', JQ_DEFS)

STATUS_PS = VARZ_PS + r'''# /healthz answers 503 when the server is not ready: JetStream not current
# with its cluster, or not started.
@DEFS@
$h = Get-Answer '/healthz'
if ($h.State -eq 'ok') { Write-Output 'metric healthy 1' } elseif ($h.State -eq 'notready') { Write-Output 'metric healthy 0' }
$js = if ($v.jetstream -and $v.jetstream.config) { 'on' } else { 'off' }
Write-Output "metric info 1 server=$(Safe $v.server_name) version=$(Safe $v.version) cluster=$(Safe $v.cluster.name) jetstream=$js"
Write-Output "metric uptime_seconds $((Ts $v.now) - (Ts $v.start))"
Write-Output "metric last_reload_seconds $((Ts $v.now) - (Ts $v.config_load_time))"
Write-Output "metric connections $($v.connections)"
Write-Output "metric max_connections $($v.max_connections)"
Write-Output "metric connections_pct $(Fmt (Pct $v.connections $v.max_connections))"
Write-Output "metric total_connections_count $($v.total_connections)"
Write-Output "metric subscriptions $($v.subscriptions)"
Write-Output "metric slow_consumers_count $($v.slow_consumers)"
if ($v.slow_consumer_stats) {
    Write-Output "metric slow_consumer_clients_count $($v.slow_consumer_stats.clients)"
    Write-Output "metric slow_consumer_routes_count $($v.slow_consumer_stats.routes)"
    Write-Output "metric slow_consumer_gateways_count $($v.slow_consumer_stats.gateways)"
    Write-Output "metric slow_consumer_leafs_count $($v.slow_consumer_stats.leafs)"
}
Write-Output "metric stale_connections_count $(Num $v.stale_connections)"
Write-Output "metric in_msgs_count $($v.in_msgs)"
Write-Output "metric out_msgs_count $($v.out_msgs)"
Write-Output "metric in_bytes_count $($v.in_bytes)"
Write-Output "metric out_bytes_count $($v.out_bytes)"
# The client with the most bytes waiting to be sent to it: the next slow
# consumer, before the server cuts it off.
$c = Get-Answer '/connz?sort=pending&limit=1'
if ($c.State -eq 'ok') {
    $top = @(($c.Body | ConvertFrom-Json).connections) | Select-Object -First 1
    $who = if ($top -and $top.name) { $top.name } elseif ($top) { "$($top.ip):$($top.port)" } else { '' }
    Write-Output "metric pending_bytes_max $(if ($top) { Num $top.pending_bytes } else { 0 }) client=$(Safe $who)"
}
'''.replace('@DEFS@', PS_DEFS)

CLUSTER_SH = VARZ_SH + r'''if [ "$(jq -r '.cluster.cluster_port // 0' "$work/varz")" = 0 ]; then
    echo "metric clustered 0"
    exit 0
fi
echo "metric clustered 1"
get '/routez' routez || { echo "$job: $url/routez did not answer" >&2; exit 1; }
jq -r --slurpfile v "$work/varz" '@DEFS@
    ([(.routes // [])[] | .remote_name] | unique) as $peers |
    "metric routes_configured \($v[0].cluster.urls // [] | length)",
    "metric route_peers \($peers | length)",
    ($peers[0:20][] | "metric route_peer 1 peer=\(t)"),
    "metric route_peer_not_shown \([($peers | length) - 20, 0] | max)",
    "metric route_connections \(.num_routes)",
    "metric route_pending_bytes \([(.routes // [])[] | .pending_size] | add // 0)",
    "metric route_rtt_max_ms \([(.routes // [])[] | .rtt | ms] | max // 0)",
    "metric leafnodes \($v[0].leafnodes // 0)"' "$work/routez"
'''.replace('@DEFS@', JQ_DEFS)

CLUSTER_PS = VARZ_PS + r'''@DEFS@
if (-not $v.cluster -or -not $v.cluster.cluster_port) { Write-Output 'metric clustered 0'; exit 0 }
Write-Output 'metric clustered 1'
$rr = Get-Answer '/routez'
if ($rr.State -ne 'ok') { [Console]::Error.WriteLine("${Job}: $($script:Url)/routez did not answer"); exit 1 }
$rz = $rr.Body | ConvertFrom-Json
$routes = @($rz.routes | Where-Object { $_ })
$peers = @($routes | ForEach-Object { [string]$_.remote_name } | Sort-Object -Unique -CaseSensitive)
Write-Output "metric routes_configured $(@($v.cluster.urls | Where-Object { $_ }).Count)"
Write-Output "metric route_peers $($peers.Count)"
foreach ($p in ($peers | Select-Object -First 20)) { Write-Output "metric route_peer 1 peer=$(Safe $p)" }
Write-Output "metric route_peer_not_shown $([Math]::Max($peers.Count - 20, 0))"
Write-Output "metric route_connections $($rz.num_routes)"
$pend = 0; foreach ($x in $routes) { $pend += [double]$x.pending_size }
Write-Output "metric route_pending_bytes $(Fmt $pend)"
$rtt = 0.0; foreach ($x in $routes) { $m = Ms $x.rtt; if ($m -gt $rtt) { $rtt = $m } }
Write-Output "metric route_rtt_max_ms $(Fmt $rtt)"
Write-Output "metric leafnodes $(Num $v.leafnodes)"
'''.replace('@DEFS@', PS_DEFS)

# A stream's or a consumer's leader: the server named in its cluster's
# leader; with no raft group (a server alone), this one; with a raft group
# and no leader, none.
JS_SH = VARZ_SH + r'''me=$(jq -r '.server_name' "$work/varz")
get '/jsz?accounts=true&streams=true&consumers=true&config=true' jsz || { echo "$job: $url/jsz did not answer" >&2; exit 1; }
jq -r --arg me "$me" '@DEFS@
def leader: if (.cluster.raft_group // "") != "" then (.cluster.leader // "") else $me end;
def top(f): sort_by(-(f)) | .[0:20];
if (.config // null) == null then "metric jetstream 0" else
    "metric jetstream 1",
    "metric memory_bytes \(.memory)",
    "metric storage_bytes \(.storage)",
    "metric max_memory_bytes \(.config.max_memory)",
    "metric max_storage_bytes \(.config.max_storage)",
    "metric memory_pct \(pct(.memory; .config.max_memory))",
    "metric storage_pct \(pct(.storage; .config.max_storage))",
    "metric streams \(.streams)",
    "metric consumers \(.consumers)",
    "metric messages \(.messages)",
    "metric bytes \(.bytes)",
    "metric api_count \(.api.total)",
    "metric api_errors_count \(.api.errors)",
    (.meta_cluster // empty |
        "metric meta_cluster_size \(.cluster_size)",
        "metric meta_leader_known \(if (.leader // "") != "" then 1 else 0 end)",
        "metric meta_is_leader \(if .leader == $me then 1 else 0 end)",
        (if .leader == $me then "metric meta_replicas_behind \([(.replicas // [])[] | select(.current != true)] | length)" else empty end)),
    ([(.account_details // [])[] | (.stream_detail // [])[]] as $all |
     [$all[] | select(leader == $me)] as $led |
     [$led[] | .name as $s | (.cluster.replicas // [])[] | select(.current != true) | {s: $s, r: .name}] as $behind |
     [$all[] | (.consumer_detail // [])[] | select(leader == $me)] as $cons |
     [$led[] | select(((.config.max_bytes // -1) > 0) or ((.config.max_msgs // -1) > 0)) |
        {s: .name, p: ([pct(.state.bytes; .config.max_bytes // -1), pct(.state.messages; .config.max_msgs // -1)] | max)}] as $lim |
        "metric streams_led \($led | length)",
        "metric streams_no_leader \([$all[] | select(leader == "")] | length)",
        "metric stream_replicas_behind \($behind | length)",
        ($behind[0:20][] | "metric stream_behind 1 stream=\(.s | t) replica=\(.r | t)"),
        "metric stream_behind_not_shown \([($behind | length) - 20, 0] | max)",
        ($led | top(.state.bytes)[] | "metric stream_messages \(.state.messages) stream=\(.name | t)", "metric stream_bytes \(.state.bytes) stream=\(.name | t)"),
        "metric stream_not_shown \([($led | length) - 20, 0] | max)",
        ($lim | top(.p)[] | "metric stream_used_pct \(.p) stream=\(.s | t)"),
        "metric stream_used_pct_not_shown \([($lim | length) - 20, 0] | max)",
        "metric consumers_led \($cons | length)",
        "metric consumers_pending \([$cons[] | .num_pending] | add // 0)",
        "metric consumers_ack_pending \([$cons[] | .num_ack_pending] | add // 0)",
        "metric consumers_redelivered \([$cons[] | .num_redelivered] | add // 0)",
        ([$cons[] | select(.num_pending > 0)] | top(.num_pending)[] | "metric consumer_pending \(.num_pending) stream=\(.stream_name | t) consumer=\(.name | t)"),
        "metric consumer_pending_not_shown \([([$cons[] | select(.num_pending > 0)] | length) - 20, 0] | max)",
        ([$cons[] | select(.num_ack_pending > 0)] | top(.num_ack_pending)[] | "metric consumer_ack_pending \(.num_ack_pending) stream=\(.stream_name | t) consumer=\(.name | t)"),
        "metric consumer_ack_pending_not_shown \([([$cons[] | select(.num_ack_pending > 0)] | length) - 20, 0] | max)",
        ([$cons[] | select(.num_redelivered > 0)] | top(.num_redelivered)[] | "metric consumer_redelivered \(.num_redelivered) stream=\(.stream_name | t) consumer=\(.name | t)"),
        "metric consumer_redelivered_not_shown \([([$cons[] | select(.num_redelivered > 0)] | length) - 20, 0] | max)")
end' "$work/jsz"
'''.replace('@DEFS@', JQ_DEFS)

JS_PS = VARZ_PS + r'''@DEFS@
$me = [string]$v.server_name
$jr = Get-Answer '/jsz?accounts=true&streams=true&consumers=true&config=true'
if ($jr.State -ne 'ok') { [Console]::Error.WriteLine("${Job}: $($script:Url)/jsz did not answer"); exit 1 }
$j = $jr.Body | ConvertFrom-Json
if (-not $j.config) { Write-Output 'metric jetstream 0'; exit 0 }
function Leader($o) { if ($o.cluster -and $o.cluster.raft_group) { [string]$o.cluster.leader } else { $me } }
function Top($list, [string]$f) { @($list | Sort-Object -Property @{ Expression = { [double]$_.$f }; Descending = $true } | Select-Object -First 20) }
function Rest($n) { [Math]::Max(@($n).Count - 20, 0) }
Write-Output 'metric jetstream 1'
Write-Output "metric memory_bytes $($j.memory)"
Write-Output "metric storage_bytes $($j.storage)"
Write-Output "metric max_memory_bytes $($j.config.max_memory)"
Write-Output "metric max_storage_bytes $($j.config.max_storage)"
Write-Output "metric memory_pct $(Fmt (Pct $j.memory $j.config.max_memory))"
Write-Output "metric storage_pct $(Fmt (Pct $j.storage $j.config.max_storage))"
Write-Output "metric streams $($j.streams)"
Write-Output "metric consumers $($j.consumers)"
Write-Output "metric messages $($j.messages)"
Write-Output "metric bytes $($j.bytes)"
Write-Output "metric api_count $($j.api.total)"
Write-Output "metric api_errors_count $($j.api.errors)"
if ($j.meta_cluster) {
    $mc = $j.meta_cluster
    Write-Output "metric meta_cluster_size $($mc.cluster_size)"
    Write-Output "metric meta_leader_known $(if ([string]$mc.leader) { 1 } else { 0 })"
    Write-Output "metric meta_is_leader $(if ([string]$mc.leader -eq $me) { 1 } else { 0 })"
    if ([string]$mc.leader -eq $me) { Write-Output "metric meta_replicas_behind $(@($mc.replicas | Where-Object { $_ -and $_.current -ne $true }).Count)" }
}
$all = @($j.account_details | Where-Object { $_ } | ForEach-Object { $_.stream_detail } | Where-Object { $_ })
$led = @($all | Where-Object { (Leader $_) -eq $me })
$behind = @(foreach ($s in $led) { foreach ($r in @($s.cluster.replicas | Where-Object { $_ })) { if ($r.current -ne $true) { [pscustomobject]@{ s = $s.name; r = $r.name } } } })
$cons = @($all | ForEach-Object { $_.consumer_detail } | Where-Object { $_ -and (Leader $_) -eq $me })
$lim = @(foreach ($s in $led) {
    $mb = if ($null -ne $s.config.max_bytes) { [double]$s.config.max_bytes } else { -1 }
    $mm = if ($null -ne $s.config.max_msgs) { [double]$s.config.max_msgs } else { -1 }
    if ($mb -gt 0 -or $mm -gt 0) { [pscustomobject]@{ s = $s.name; p = [Math]::Max((Pct $s.state.bytes $mb), (Pct $s.state.messages $mm)) } }
})
Write-Output "metric streams_led $($led.Count)"
Write-Output "metric streams_no_leader $(@($all | Where-Object { (Leader $_) -eq '' }).Count)"
Write-Output "metric stream_replicas_behind $($behind.Count)"
foreach ($b in ($behind | Select-Object -First 20)) { Write-Output "metric stream_behind 1 stream=$(Safe $b.s) replica=$(Safe $b.r)" }
Write-Output "metric stream_behind_not_shown $(Rest $behind)"
foreach ($s in (Top ($led | ForEach-Object { [pscustomobject]@{ name = $_.name; messages = $_.state.messages; bytes = $_.state.bytes } }) 'bytes')) {
    Write-Output "metric stream_messages $($s.messages) stream=$(Safe $s.name)"
    Write-Output "metric stream_bytes $($s.bytes) stream=$(Safe $s.name)"
}
Write-Output "metric stream_not_shown $(Rest $led)"
foreach ($l in (Top $lim 'p')) { Write-Output "metric stream_used_pct $(Fmt $l.p) stream=$(Safe $l.s)" }
Write-Output "metric stream_used_pct_not_shown $(Rest $lim)"
Write-Output "metric consumers_led $($cons.Count)"
$sp = 0; $sa = 0; $sr = 0
foreach ($c in $cons) { $sp += [double]$c.num_pending; $sa += [double]$c.num_ack_pending; $sr += [double]$c.num_redelivered }
Write-Output "metric consumers_pending $(Fmt $sp)"
Write-Output "metric consumers_ack_pending $(Fmt $sa)"
Write-Output "metric consumers_redelivered $(Fmt $sr)"
foreach ($f in @(@('num_pending', 'consumer_pending'), @('num_ack_pending', 'consumer_ack_pending'), @('num_redelivered', 'consumer_redelivered'))) {
    $some = @($cons | Where-Object { [double]$_.($f[0]) -gt 0 })
    foreach ($c in (Top $some $f[0])) { Write-Output "metric $($f[1]) $($c.($f[0])) stream=$(Safe $c.stream_name) consumer=$(Safe $c.name)" }
    Write-Output "metric $($f[1])_not_shown $(Rest $some)"
}
'''.replace('@DEFS@', PS_DEFS)

EXIT_SH = ("0, whatever it reads, and when @P@ does not answer (up 0 is the reading); 1 when it answers wrong (not "
           "HTTP, a page missing), said on stderr, or curl or jq is missing")
EXIT_PS = ("0, whatever it reads, and when @P@ does not answer (up 0 is the reading); 1 when it answers wrong (not "
           "HTTP, a page missing), said on stderr")

job(pack='nats', job='status', metric='', when='run_every   = 1m', runtime='30s',
    title='is this NATS server healthy, and are its clients keeping up',
    what="Reports whether the server answers and is healthy (ready, and with JetStream on, current with its "
         "cluster), what it is, how long since it started and since its configuration last loaded, its "
         "connections against its limit, its subscriptions, the slow consumers it has cut off (clients, routes, "
         "gateways and leaf nodes that could not keep up), stale connections, the messages and bytes in and out, "
         "and the client with the most bytes waiting to be sent to it, named.",
    reads=READS + ": /varz, /healthz and /connz?sort=pending&limit=1.",
    needs_sh=['curl', 'jq'], exit_sh=EXIT_SH, exit_ps=EXIT_PS,
    steps=[code(STATUS_SH, STATUS_PS, [
        ('up', '1 when the server answered, else 0 (and nothing more is read)'),
        ('healthy', '1 when /healthz answers ok; 0 when it answers 503: not ready, or JetStream not current with its cluster'),
        ('info', 'always 1, tagged server=<its name>, version=, cluster=<its name, or none> and jetstream=<on or off>'),
        ('uptime_seconds', 'since the server started'),
        ('last_reload_seconds', 'since its configuration last loaded (started, or reloaded)'),
        ('connections', 'clients connected'),
        ('max_connections', 'the most it allows (max_connections)'),
        ('connections_pct', 'connections, of max_connections'),
        ('total_connections_count', 'clients that have connected (a running total)'),
        ('subscriptions', 'subscriptions, routes\' and the system\'s included'),
        ('slow_consumers_count', 'connections it cut off for not reading fast enough (a running total)'),
        ('slow_consumer_clients_count', 'of them, clients (a running total; 2.10 and later, as the next three)'),
        ('slow_consumer_routes_count', 'routes to other servers of its cluster'),
        ('slow_consumer_gateways_count', 'gateways to other clusters'),
        ('slow_consumer_leafs_count', 'leaf nodes'),
        ('stale_connections_count', 'connections closed for not answering its pings (a running total)'),
        ('in_msgs_count', 'messages received, from clients and other servers (a running total)'),
        ('out_msgs_count', 'messages sent (a running total)'),
        ('in_bytes_count', 'bytes received (a running total)'),
        ('out_bytes_count', 'bytes sent (a running total)'),
        ('pending_bytes_max', 'bytes waiting to be sent to the client furthest behind, tagged client=<its name, or address:port>'),
    ])],
    healthy='up 1; healthy 1; connections_pct well below 80; slow_consumers_count flat; pending_bytes_max small.',
    watch='connections_pct above 80; pending_bytes_max growing: that client is falling behind (client says which).',
    act='up 0 or healthy 0; slow_consumers_count moving: the server is cutting off clients (or routes) that cannot keep '
        'up, and they lose messages; connections_pct near 100: new clients are refused.')

job(pack='nats', job='cluster', metric='cluster', when='run_every   = 1m', runtime='30s',
    title="a NATS server's routes to the rest of its cluster",
    what="Reports whether the server is in a cluster, the routes configured, the other servers it has routes to, "
         "each named, the route connections (2.10 and later pool several to each server), the bytes waiting on "
         "them, the slowest round trip, and its leaf nodes.",
    reads=READS + ": /varz and /routez.",
    needs_sh=['curl', 'jq'], exit_sh=EXIT_SH, exit_ps=EXIT_PS,
    steps=[code(CLUSTER_SH, CLUSTER_PS, [
        ('up', '1 when the server answered, else 0 (and nothing more is read)'),
        ('clustered', '1 when it has a cluster port; 0 alone (and nothing more is read)'),
        ('routes_configured', 'routes in its configuration (cluster.routes): the servers it is told to reach'),
        ('route_peers', 'other servers of its cluster it has a route to'),
        ('route_peer', 'always 1, one line for each of them, tagged peer=<its name>'),
        ('route_peer_not_shown', 'how many more there were than the 20 shown'),
        ('route_connections', 'route connections: with route pooling (2.10 and later), several to each server'),
        ('route_pending_bytes', 'bytes waiting to be sent on its routes'),
        ('route_rtt_max_ms', 'the slowest route\'s round trip, in milliseconds'),
        ('leafnodes', 'leaf node connections'),
    ])],
    healthy='route_peers the cluster\'s size less one, steady; route_pending_bytes near 0.',
    watch='route_rtt_max_ms well above its usual; route_pending_bytes growing.',
    act='route_peers below the cluster\'s size less one: a server is down or cut off (route_peer says which are '
        'there); with JetStream, a cluster that loses more than half its servers stops accepting writes.')

job(pack='nats', job='jetstream', metric='jetstream', when='run_every   = 1m', runtime='30s',
    title="a NATS server's JetStream: storage, the meta leader, streams and consumers",
    what="Reports whether JetStream is on, its memory and file storage against the limits it was given, its "
         "streams, consumers, messages and bytes on this server, its API calls and errors; in a cluster, the meta "
         "leader, whether it is known and whether it is this server, and, on the leader, the servers behind. Then, "
         "for the streams and consumers this server leads: the replicas behind, each named; each stream's messages "
         "and bytes, and how full it is against its own limits (max_bytes, max_msgs); the messages consumers have "
         "not been given, those given and not acked, and those redelivered, each consumer named. And the streams "
         "with no leader, which take no writes. Only a stream's leader reports it, so a cluster's streams are "
         "counted once: sum them by stream in the backend.",
    reads=READS + ": /varz and /jsz?accounts=true&streams=true&consumers=true&config=true.",
    needs_sh=['curl', 'jq'], exit_sh=EXIT_SH, exit_ps=EXIT_PS,
    steps=[code(JS_SH, JS_PS, [
        ('up', '1 when the server answered, else 0 (and nothing more is read)'),
        ('jetstream', '1 when JetStream is on; 0 (and nothing more) when it is off'),
        ('memory_bytes', 'memory its streams use'),
        ('storage_bytes', 'file storage its streams use'),
        ('max_memory_bytes', 'the memory it may use (max_memory_store)'),
        ('max_storage_bytes', 'the file storage it may use (max_file_store)'),
        ('memory_pct', 'memory_bytes, of max_memory_bytes'),
        ('storage_pct', 'storage_bytes, of max_storage_bytes'),
        ('streams', 'streams on this server, replicas included'),
        ('consumers', 'consumers on this server, replicas included'),
        ('messages', 'messages in them'),
        ('bytes', 'bytes in them'),
        ('api_count', 'JetStream API calls (a running total)'),
        ('api_errors_count', 'of them, errors: a stream full, a stream or consumer not found, no leader (a running total)'),
        ('meta_cluster_size', 'servers in the JetStream cluster'),
        ('meta_leader_known', '1 when it knows the meta leader; 0: no leader, so no stream or consumer can be made or changed'),
        ('meta_is_leader', '1 on the meta leader'),
        ('meta_replicas_behind', 'on the meta leader: servers not current with it'),
        ('streams_led', 'streams this server leads: the rest below are theirs'),
        ('streams_no_leader', 'streams it holds a replica of that have no leader: they take no writes'),
        ('stream_replicas_behind', 'replicas of its streams not current with it'),
        ('stream_behind', 'always 1, one line for each, tagged stream= and replica=<the server>'),
        ('stream_behind_not_shown', 'how many more there were than the 20 shown'),
        ('stream_messages', 'messages in a stream, tagged stream= (the 20 largest)'),
        ('stream_bytes', 'bytes in a stream, tagged stream='),
        ('stream_not_shown', 'streams past the 20 shown'),
        ('stream_used_pct', 'how full a stream with limits is, of max_bytes or max_msgs, whichever is fuller, tagged stream='),
        ('stream_used_pct_not_shown', 'how many more there were than the 20 shown'),
        ('consumers_led', 'consumers this server leads'),
        ('consumers_pending', 'messages their consumers have not been given yet, all together'),
        ('consumers_ack_pending', 'messages given and not acked yet, all together'),
        ('consumers_redelivered', 'messages given more than once, all together'),
        ('consumer_pending', 'one consumer\'s messages not given yet, tagged stream= and consumer= (the 20 furthest behind)'),
        ('consumer_pending_not_shown', 'how many more there were than the 20 shown'),
        ('consumer_ack_pending', 'one consumer\'s messages given and not acked'),
        ('consumer_ack_pending_not_shown', 'how many more there were than the 20 shown'),
        ('consumer_redelivered', 'one consumer\'s messages given more than once'),
        ('consumer_redelivered_not_shown', 'how many more there were than the 20 shown'),
    ])],
    healthy='jetstream 1; storage_pct and memory_pct below 75; meta_leader_known 1; streams_no_leader 0; '
            'stream_replicas_behind 0; consumer_pending steady or falling.',
    watch='storage_pct or memory_pct above 75; a stream_used_pct above 90 (at its limit it drops its oldest messages, '
          'or refuses new ones); consumer_pending growing run after run: that consumer is falling behind; '
          'consumer_redelivered growing: its messages are not being acked in time.',
    act='meta_leader_known 0 or streams_no_leader above 0: the cluster has lost its majority, and those streams take '
        'no writes; stream_replicas_behind above 0 for long: a server is down or cannot keep up (stream_behind says '
        'which); storage_pct near 100: publishes to its streams fail; api_errors_count moving fast.')
