#Requires -Version 5.1

<#
.SYNOPSIS
    traffic.ps1 - each RabbitMQ node's messages: in, routed, out, acknowledged, lost; and its clients coming and going
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reads each node's Prometheus page (rabbitmq_prometheus, port 15692), from RABBITMQ_TARGETS
    (<name>=<address> separated by ;), and reports
    its running totals since it started: graph them as rates. Every protocol
    (AMQP 0-9-1, AMQP 1.0, MQTT, STOMP, streams) and queue type, added up.

    Metrics:
      nodes                       the nodes named in RABBITMQ_TARGETS
      up                          1 when the node's page answers, else 0,
                                  tagged node=<its name>
      received_count              messages published to it
      received_confirm_count      of those, by publishers asking for confirms
      confirmed_count             publishes it confirmed
      routed_count                messages routed to at least one queue
      unroutable_dropped_count    messages no queue took, dropped
      unroutable_returned_count   messages no queue took, returned to the
                                  publisher (mandatory)
      delivered_count             messages delivered to consumers and gets
      delivered_manual_ack_count  of those, to be acknowledged by the client
      delivered_auto_ack_count    of those, acknowledged on delivery
      redelivered_count           deliveries of a message delivered before
      acknowledged_count          messages acknowledged by clients
      get_empty_count             basic.get on an empty queue (polling)
      dead_lettered_count         messages dead-lettered, tagged
                                  reason=<expired, maxlen, rejected or
                                  delivery_limit>
      unacked                     messages delivered and not yet acknowledged,
                                  on every channel
      unconfirmed                 publishes not yet confirmed, on every
                                  channel
      message_avg_bytes           the average size of a message published
      connections_opened_count    connections opened
      connections_closed_count    connections closed
      channels_opened_count       channels opened
      channels_closed_count       channels closed
      queues_declared_count       queue declarations
      queues_created_count        queues created
      queues_deleted_count        queues deleted
      logins_count                logins tried
      logins_failed_count         logins refused

    Example output:
      metric nodes 1
      metric up 1 node=rabbit1

    Reading the results (starting points: tune them to the node; graph the
    _count totals as rates):
      Healthy  delivered_count and acknowledged_count rising with
               received_count; unroutable and dead_lettered flat;
               connections opened and closed at a low, steady rate.
      Watch    redelivered_count rising: consumers failing or rejecting;
               get_empty_count rising fast: clients polling, not consuming;
               unacked climbing: consumers slow to acknowledge;
               connections_opened_count rising as fast as closed, by many a
               second: clients connecting for every message (churn).
      Act      unroutable_dropped_count rising: messages lost, published
               where no queue is bound; dead_lettered_count reason=maxlen or
               expired rising: queues full or messages too old, and
               dropped if there is no dead letter queue; logins_failed_count
               rising: a client with a wrong password, or someone trying.

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
        if ($_.Exception.Response) { [Console]::Error.WriteLine("traffic: $url did not give a page: $($_.Exception.Message)"); return 'error' }
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
        [Console]::Error.WriteLine("traffic: RABBITMQ_TARGETS: '$entry' is not <name>=<address>, as in rabbit1=http://127.0.0.1:15692")
        exit 1
    }
    $name = $entry.Substring(0, $i).Trim() -replace '[^A-Za-z0-9@._:-]', '_'
    $url = $entry.Substring($i + 1).Trim().TrimEnd('/')
    $page = Get-Page ($url + $path)
    if ($null -eq $page) { Write-Output "metric up 0 node=$name"; return $null }
    if ($page -is [string] -and $page -eq 'error') { Write-Output "metric up 0 node=$name"; $script:code = 1; return $null }
    if (-not ($page | Where-Object { $_.StartsWith('rabbitmq_build_info') })) {
        Write-Output "metric up 0 node=$name"
        [Console]::Error.WriteLine("traffic: ${name}: $url$path answers, but is not RabbitMQ's Prometheus page")
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
    # What it printed (up 1 or 0), then the node's page, if it gave one.
    $t | Where-Object { $_ -is [string] } | ForEach-Object { Write-Output $_ }
    $t = @($t | Where-Object { $_ -is [hashtable] })[0]
    if (-not $t) { continue }
    $tag = "node=$($t.Name)"
    $s = Get-Sums $t.Page
    function Out-M($m, $b) { if ($s.ContainsKey($b)) { Write-Output "metric $m $(Num $s[$b]) $tag" } }
    function Out-2($m, $a, $b) { if ($s.ContainsKey($a) -or $s.ContainsKey($b)) { Write-Output "metric $m $(Num ([double]$s[$a] + [double]$s[$b])) $tag" } }
    Out-M received_count rabbitmq_global_messages_received_total
    Out-M received_confirm_count rabbitmq_global_messages_received_confirm_total
    Out-M confirmed_count rabbitmq_global_messages_confirmed_total
    Out-M routed_count rabbitmq_global_messages_routed_total
    Out-M unroutable_dropped_count rabbitmq_global_messages_unroutable_dropped_total
    Out-M unroutable_returned_count rabbitmq_global_messages_unroutable_returned_total
    Out-M delivered_count rabbitmq_global_messages_delivered_total
    Out-2 delivered_manual_ack_count rabbitmq_global_messages_delivered_consume_manual_ack_total rabbitmq_global_messages_delivered_get_manual_ack_total
    Out-2 delivered_auto_ack_count rabbitmq_global_messages_delivered_consume_auto_ack_total rabbitmq_global_messages_delivered_get_auto_ack_total
    Out-M redelivered_count rabbitmq_global_messages_redelivered_total
    Out-M acknowledged_count rabbitmq_global_messages_acknowledged_total
    Out-M get_empty_count rabbitmq_global_messages_get_empty_total
    foreach ($r in 'expired', 'maxlen', 'rejected', 'delivery_limit') {
        $b = "rabbitmq_global_messages_dead_lettered_${r}_total"
        if ($s.ContainsKey($b)) { Write-Output "metric dead_lettered_count $(Num $s[$b]) $tag reason=$r" }
    }
    Out-M unacked rabbitmq_channel_messages_unacked
    Out-M unconfirmed rabbitmq_channel_messages_unconfirmed
    if ($s.ContainsKey('rabbitmq_message_size_bytes_count') -and $s['rabbitmq_message_size_bytes_count'] -gt 0) {
        Write-Output "metric message_avg_bytes $(Num ($s['rabbitmq_message_size_bytes_sum'] / $s['rabbitmq_message_size_bytes_count'])) $tag"
    }
    Out-M connections_opened_count rabbitmq_connections_opened_total
    Out-M connections_closed_count rabbitmq_connections_closed_total
    Out-M channels_opened_count rabbitmq_channels_opened_total
    Out-M channels_closed_count rabbitmq_channels_closed_total
    Out-M queues_declared_count rabbitmq_queues_declared_total
    Out-M queues_created_count rabbitmq_queues_created_total
    Out-M queues_deleted_count rabbitmq_queues_deleted_total
    Out-M logins_count rabbitmq_auth_attempts_total
    Out-M logins_failed_count rabbitmq_auth_attempts_failed_total
}
exit $code
