#Requires -Version 5.1

<#
.SYNOPSIS
    jetstream.ps1 - a NATS server's JetStream: storage, the meta leader, streams and consumers, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports whether JetStream is on, its memory and file storage against the
    limits it was given, its streams, consumers, messages and bytes on this
    server, its API calls and errors; in a cluster, the meta leader, whether it
    is known and whether it is this server, and, on the leader, the servers
    behind. Then, for the streams and consumers this server leads: the replicas
    behind, each named; each stream's messages and bytes, and how full it is
    against its own limits (max_bytes, max_msgs); the messages consumers have
    not been given, those given and not acked, and those redelivered, each
    consumer named. And the streams with no leader, which take no writes. Only a
    stream's leader reports it, so a cluster's streams are counted once: sum
    them by stream in the backend. It only reads: every request is a GET, and it
    changes nothing.

    Reads NATS_URL (default http://localhost:8222), its monitoring port: /varz
    and /jsz?accounts=true&streams=true&consumers=true&config=true.
    What the scripts share is in _nats.ps1, beside this one.

    Metrics:
      up                              1 when the server answered, else 0 (and
                                      nothing more is read)
      jetstream                       1 when JetStream is on; 0 (and nothing
                                      more) when it is off
      memory_bytes                    memory its streams use
      storage_bytes                   file storage its streams use
      max_memory_bytes                the memory it may use (max_memory_store)
      max_storage_bytes               the file storage it may use
                                      (max_file_store)
      memory_pct                      memory_bytes, of max_memory_bytes
      storage_pct                     storage_bytes, of max_storage_bytes
      streams                         streams on this server, replicas included
      consumers                       consumers on this server, replicas
                                      included
      messages                        messages in them
      bytes                           bytes in them
      api_count                       JetStream API calls (a running total)
      api_errors_count                of them, errors: a stream full, a stream
                                      or consumer not found, no leader (a
                                      running total)
      meta_cluster_size               servers in the JetStream cluster
      meta_leader_known               1 when it knows the meta leader; 0: no
                                      leader, so no stream or consumer can be
                                      made or changed
      meta_is_leader                  1 on the meta leader
      meta_replicas_behind            on the meta leader: servers not current
                                      with it, or offline (a few seconds after a
                                      new leader is elected)
      meta_behind                     always 1, one line for each, tagged
                                      server=<its name>
      meta_behind_not_shown           how many more there were than the 20 shown
      streams_led                     streams this server leads: the rest below
                                      are theirs
      streams_no_leader               streams it holds a replica of that have no
                                      leader: they take no writes
      stream_replicas_behind          replicas of its streams not current with
                                      it
      stream_behind                   always 1, one line for each, tagged
                                      stream= and replica=<the server>
      stream_behind_not_shown         how many more there were than the 20 shown
      stream_messages                 messages in a stream, tagged stream= (the
                                      20 largest)
      stream_bytes                    bytes in a stream, tagged stream=
      stream_not_shown                streams past the 20 shown
      stream_used_pct                 how full a stream with limits is, of
                                      max_bytes or max_msgs, whichever is
                                      fuller, tagged stream=
      stream_used_pct_not_shown       how many more there were than the 20 shown
      consumers_led                   consumers this server leads
      consumers_pending               messages their consumers have not been
                                      given yet, all together
      consumers_ack_pending           messages given and not acked yet, all
                                      together
      consumers_redelivered           messages given more than once, all
                                      together
      consumer_pending                one consumer's messages not given yet,
                                      tagged stream= and consumer= (the 20
                                      furthest behind)
      consumer_pending_not_shown      how many more there were than the 20 shown
      consumer_ack_pending            one consumer's messages given and not
                                      acked
      consumer_ack_pending_not_shown  how many more there were than the 20 shown
      consumer_redelivered            one consumer's messages given more than
                                      once
      consumer_redelivered_not_shown  how many more there were than the 20 shown

    Example output (the rest are in the same form):
      metric up 1
      metric jetstream 1
      metric memory_bytes 0
      metric storage_bytes 89235
      metric max_memory_bytes 6141358080
      metric max_storage_bytes 53622297600
      metric memory_pct 0
      metric storage_pct 0
      metric streams 2
      metric consumers 1
      metric messages 561
      metric bytes 89235
      metric api_count 6
      metric api_errors_count 1
      metric meta_cluster_size 3
      metric meta_leader_known 1
      metric meta_is_leader 1
      metric meta_replicas_behind 0
      metric streams_led 0
      metric streams_no_leader 0
      metric stream_replicas_behind 0
      metric consumers_led 1
      metric consumers_pending 450
      metric consumers_ack_pending 50
      metric consumers_redelivered 50
      metric consumer_pending 450 stream=ORDERS consumer=billing
      metric consumer_ack_pending 50 stream=ORDERS consumer=billing
      metric consumer_redelivered 50 stream=ORDERS consumer=billing

    Reading the results (starting points: tune them to your own):
      Healthy  jetstream 1; storage_pct and memory_pct below 75;
               meta_leader_known 1; streams_no_leader 0; stream_replicas_behind
               0; consumer_pending steady or falling.
      Watch    storage_pct or memory_pct above 75; a stream_used_pct above 90
               (at its limit it drops its oldest messages, or refuses new ones);
               consumer_pending growing run after run: that consumer is falling
               behind; consumer_redelivered growing: its messages are not being
               acked in time.
      Act      meta_leader_known 0 or streams_no_leader above 0: the cluster has
               lost its majority, and those streams take no writes;
               stream_replicas_behind above 0 for long: a server is down or
               cannot keep up (stream_behind says which); storage_pct near 100:
               publishes to its streams fail; api_errors_count moving fast.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0, whatever it reads, and when NATS does not answer (up 0 is the
      reading); 1 when it answers wrong (not HTTP, a page missing), said on
      stderr
#>

$Job = 'jetstream'
. (Join-Path $PSScriptRoot '_nats.ps1')

$r = Get-Answer '/varz'
switch ($r.State) {
    'ok' { Write-Output 'metric up 1' }
    'down' { Write-Output 'metric up 0'; exit 0 }
    'notready' { Write-Output 'metric up 0'; exit 0 }
    'missing' { Write-Output 'metric up 0'; [Console]::Error.WriteLine("${Job}: $($script:Url)/varz: no such page (HTTP 404): is NATS_URL its monitoring port (-m 8222)?"); exit 0 }
    default { Write-Output 'metric up 0'; [Console]::Error.WriteLine("${Job}: $($r.Why)"); exit 1 }
}
$v = $r.Body | ConvertFrom-Json
function Ts($s) {
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

$me = [string]$v.server_name
$jr = Get-Answer '/jsz?accounts=true&streams=true&consumers=true&config=true'
if ($jr.State -ne 'ok') { [Console]::Error.WriteLine("${Job}: $($script:Url)/jsz did not answer"); exit 1 }
$j = $jr.Body | ConvertFrom-Json
if ($j.disabled -eq $true -or -not $j.config) { Write-Output 'metric jetstream 0'; exit 0 }
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
    if ([string]$mc.leader -eq $me) {
        $mb = @($mc.replicas | Where-Object { $_ -and ($_.current -ne $true -or $_.offline -eq $true) } | ForEach-Object { [string]$_.name })
        Write-Output "metric meta_replicas_behind $($mb.Count)"
        foreach ($n in ($mb | Select-Object -First 20)) { Write-Output "metric meta_behind 1 server=$(Safe $n)" }
        Write-Output "metric meta_behind_not_shown $(Rest $mb)"
    }
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
exit 0
