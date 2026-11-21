# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# A fragment of the kafka pack: tools/kafka/gen.py writes packs/kafka from it.

    # The settings that matter most for safety, from every broker:
    #   All configs for broker 1 are:
    #     unclean.leader.election.enable=false sensitive=false synonyms={...}
    # reported from the first, with a count of those that differ between
    # brokers; then the topics whose own settings put their data at risk.
    if ((Invoke-Kafka 'kafka-configs' ($conn + @('--describe', '--entity-type', 'brokers', '--all'))) -ne 0) { return }
    $first = ''; $b = ''; $cfgs = New-Map; $seen = New-Map; $diff = New-Map
    $own = '^(listeners|advertised\.listeners|broker\.id|node\.id|broker\.rack)$'
    foreach ($l in ($script:out -split "`r?`n")) {
        if ($l -cmatch '^All configs for broker (\S+) are') { $b = $Matches[1]; if (-not $first) { $first = $b }; continue }
        if ($l -cnotmatch '^  ([a-z.]+)=(.*?) sensitive=(true|false) synonyms=') { continue }
        $k = $Matches[1]; $v = $Matches[2]
        if ($seen.Contains($k) -and $seen[$k] -cne $v -and $k -cnotmatch $own) { $diff[$k] = 1 }
        $seen[$k] = $v
        if ($b -ceq $first) { $cfgs[$k] = $v }
    }
    if ((Invoke-Kafka 'kafka-topics' ($conn + @('--describe'))) -ne 0) { return }
    $d = Read-Describe $script:out
    $unclean = 0; $strict = 0; $weak = 0
    foreach ($t in $d.Topics) {
        if ($t.Configs -cmatch '(^|[ ,])unclean\.leader\.election\.enable=true') { $unclean++ }
        if ($t.Rf -gt 1 -and $t.MinIsr -ge $t.Rf) { $strict++ }
        if ($t.Rf -ge 3 -and $t.MinIsr -le 1) { $weak++ }
    }
    $bool = { param($k) [int]($cfgs[$k] -ceq 'true') }
    Write-Output "metric unclean_leader_election $(& $bool 'unclean.leader.election.enable')"
    Write-Output "metric auto_create_topics $(& $bool 'auto.create.topics.enable')"
    Write-Output "metric auto_leader_rebalance $(& $bool 'auto.leader.rebalance.enable')"
    $az = [string]$cfgs['authorizer.class.name']
    Write-Output "metric authorizer $([int]($az -and $az -cne 'null'))"
    foreach ($x in @(@('min.insync.replicas', 'min_insync_replicas'), @('default.replication.factor', 'default_replication_factor'),
            @('offsets.topic.replication.factor', 'offsets_replication_factor'), @('transaction.state.log.replication.factor', 'transactions_replication_factor'),
            @('message.max.bytes', 'message_max_bytes'))) {
        if ([string]$cfgs[$x[0]] -cmatch '^\d+$') { Write-Output "metric $($x[1]) $($cfgs[$x[0]])" }
    }
    # Retention: log.retention.ms, else .minutes, else .hours; -1 is forever.
    $h = $null
    if ([string]$cfgs['log.retention.ms'] -cmatch '^-?\d+$') { $h = if ([long]$cfgs['log.retention.ms'] -lt 0) { -1 } else { [double]$cfgs['log.retention.ms'] / 3600000 } }
    elseif ([string]$cfgs['log.retention.minutes'] -cmatch '^-?\d+$') { $h = if ([long]$cfgs['log.retention.minutes'] -lt 0) { -1 } else { [double]$cfgs['log.retention.minutes'] / 60 } }
    elseif ([string]$cfgs['log.retention.hours'] -cmatch '^-?\d+$') { $h = [double]$cfgs['log.retention.hours'] }
    if ($null -ne $h) { Write-Output ("metric retention_hours " + [Math]::Round($h, 2).ToString('0.##', [System.Globalization.CultureInfo]::InvariantCulture)) }
    # Listeners without TLS or a login, but for the controllers.
    $proto = New-Map
    foreach ($pm in ([string]$cfgs['listener.security.protocol.map'] -split ',')) { $kv = $pm -split ':'; if ($kv.Count -eq 2) { $proto[$kv[0]] = $kv[1] } }
    $ctl = @([string]$cfgs['controller.listener.names'] -split ',')
    $plain = 0
    foreach ($ls in ([string]$cfgs['listeners'] -split ',')) {
        $name = $ls -replace '://.*$', ''
        if ($name -and $ctl -cnotcontains $name -and $proto[$name] -ceq 'PLAINTEXT') { $plain++ }
    }
    Write-Output "metric plaintext_listeners $plain"
    Write-Output "metric settings_differ $($diff.Count)"
    Write-Output "metric topics_unclean_election $unclean"
    Write-Output "metric topics_min_isr_ge_rf $strict"
    Write-Output "metric topics_min_isr_1 $weak"
