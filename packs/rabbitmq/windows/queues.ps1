#Requires -Version 5.1

<#
.SYNOPSIS
    queues.ps1 - each RabbitMQ queue, the deepest first: messages waiting, unacknowledged, consumers, how busy they keep them, the oldest message
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reads each node's detailed Prometheus page (rabbitmq_prometheus,
    /metrics/detailed, port 15692), from RABBITMQ_TARGETS
    (<name>=<address> separated by ;): the queues that node holds. A quorum
    queue is reported by the node that leads it, not its followers, so name
    every node of a cluster and each queue is counted once. Past 100 queues
    on a node, the deepest 100, and the rest counted.

    Metrics:
      nodes                     the nodes named in RABBITMQ_TARGETS
      up                        1 when the node's page answers, else 0,
                                tagged node=<its name>
      queues                    the queues this node leads
      messages_total            messages in them all
      without_consumers         queues holding messages with no consumer
      messages                  messages in one queue, ready and
                                unacknowledged, tagged node=<its name>,
                                vhost=<its vhost>, queue=<its name> and
                                type=<classic, quorum or stream>
      ready                     of those, waiting for a consumer
      unacked                   of those, delivered and not yet acknowledged
      consumers                 its consumers
      utilisation_pct           how much of the time its consumers can take
                                a message at once (100: they keep up; low:
                                they are slow, or their prefetch too small).
                                Classic queues; a quorum queue says 100
                                while it has a consumer, slow or not: read
                                its ready rising instead
      bytes                     the size of its messages
      memory_bytes              the memory its process holds
      oldest_seconds            how old its oldest message is (when
                                publishers set the timestamp property)
      published_count           messages published to it (a running total)
      queues_not_shown          past the deepest 100, how many were left out

    Example output:
      metric nodes 1
      metric up 1 node=rabbit1

    Reading the results (starting points: tune them to the queue):
      Healthy  ready near 0, or steady, for queues with consumers;
               utilisation_pct near 100; without_consumers 0.
      Watch    ready growing run after run: consumers fall behind;
               utilisation_pct low with ready above 0: consumers are slow,
               or their prefetch is too small; unacked near consumers times
               their prefetch: every consumer is busy.
      Act      without_consumers above 0 for a queue that should have them:
               its consumers are gone, and messages pile up; oldest_seconds
               past what your consumers promise; messages_total climbing
               with the node's memory_pct (rabbitmq_status): the memory
               alarm is next, and it blocks every publisher.

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
        if ($_.Exception.Response) { [Console]::Error.WriteLine("queues: $url did not give a page: $($_.Exception.Message)"); return 'error' }
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
        [Console]::Error.WriteLine("queues: RABBITMQ_TARGETS: '$entry' is not <name>=<address>, as in rabbit1=http://127.0.0.1:15692")
        exit 1
    }
    $name = $entry.Substring(0, $i).Trim() -replace '[^A-Za-z0-9@._:-]', '_'
    $url = $entry.Substring($i + 1).Trim().TrimEnd('/')
    $page = Get-Page ($url + $path)
    if ($null -eq $page) { Write-Output "metric up 0 node=$name"; return $null }
    if ($page -is [string] -and $page -eq 'error') { Write-Output "metric up 0 node=$name"; $script:code = 1; return $null }
    if (-not ($page | Where-Object { $_.StartsWith('rabbitmq_build_info') })) {
        Write-Output "metric up 0 node=$name"
        [Console]::Error.WriteLine("queues: ${name}: $url$path answers, but is not RabbitMQ's Prometheus page")
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

$families = '?family=queue_coarse_metrics&family=queue_consumer_count&family=queue_metrics&family=queue_exchange_metrics'
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
foreach ($entry in $targets) {
    $t = Read-Target $entry ('/metrics/detailed' + $families)
    if ($t -isnot [hashtable]) { $t | Where-Object { $_ -is [string] } | ForEach-Object { Write-Output $_ }; continue }
    $tag = "node=$($t.Name)"
    $q = @{}
    foreach ($l in $t.Page) {
        if (-not $l.StartsWith('rabbitmq_detailed_queue_')) { continue }
        $p = $l -split '\s+'
        $base = ($p[0] -replace '\{.*$', '') -replace '^rabbitmq_detailed_queue_', ''
        $key = (Label $p[0] 'vhost') + "`t" + (Label $p[0] 'queue')
        if (-not $q.ContainsKey($key)) { $q[$key] = @{} }
        if ($base -eq 'info') {
            $q[$key]['type'] = (Label $p[0] 'queue_type') -replace '^rabbit_', '' -replace '_queue$', ''
            $q[$key]['member'] = Label $p[0] 'membership'
            continue
        }
        $v = 0.0; [void][double]::TryParse($p[1], [Globalization.NumberStyles]::Float, $inv, [ref]$v)
        if ($base -eq 'exchange_messages_published_total') { $q[$key][$base] = [double]$q[$key][$base] + $v } else { $q[$key][$base] = $v }
    }
    $rows = @($q.GetEnumerator() | Where-Object { $_.Value['member'] -ne 'follower' } | Sort-Object { [double]$_.Value['messages'] } -Descending)
    $total = 0.0; $idle = 0
    foreach ($r in $rows) { $total += [double]$r.Value['messages']; if ([double]$r.Value['messages'] -gt 0 -and [double]$r.Value['consumers'] -eq 0) { $idle++ } }
    Write-Output "metric queues $($rows.Count) $tag"
    Write-Output "metric messages_total $(Num $total) $tag"
    Write-Output "metric without_consumers $idle $tag"
    foreach ($r in ($rows | Select-Object -First 100)) {
        $vq = $r.Key.Split("`t"); $v = $r.Value
        $type = if ($v['type']) { $v['type'] } else { 'unknown' }
        $qt = "$tag vhost=$(Safe $vq[0]) queue=$(Safe $vq[1]) type=$type"
        Write-Output "metric messages $(Num ([double]$v['messages'])) $qt"
        Write-Output "metric ready $(Num ([double]$v['messages_ready'])) $qt"
        Write-Output "metric unacked $(Num ([double]$v['messages_unacked'])) $qt"
        Write-Output "metric consumers $(Num ([double]$v['consumers'])) $qt"
        if ($v.ContainsKey('consumer_utilisation')) { Write-Output "metric utilisation_pct $(Num (100 * $v['consumer_utilisation']) '0.00') $qt" }
        if ($v.ContainsKey('messages_bytes')) { Write-Output "metric bytes $(Num $v['messages_bytes']) $qt" }
        if ($v.ContainsKey('process_memory_bytes')) { Write-Output "metric memory_bytes $(Num $v['process_memory_bytes']) $qt" }
        $ts = [double]$v['head_message_timestamp']
        if ($ts -gt 100000000000) { $ts = $ts / 1000 }
        if ($ts -gt 0 -and $now -ge $ts) { Write-Output "metric oldest_seconds $(Num ($now - $ts)) $qt" }
        if ($v.ContainsKey('exchange_messages_published_total')) { Write-Output "metric published_count $(Num $v['exchange_messages_published_total']) $qt" }
    }
    Write-Output "metric queues_not_shown $([Math]::Max(0, $rows.Count - 100)) $tag"
}
exit $code
