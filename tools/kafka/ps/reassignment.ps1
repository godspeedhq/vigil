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

    # The partition moves in progress, as the cluster lists them:
    #   orders-0: replicas: 2,1. adding: 2. removing: 1.
    # A topic's name may hold a "-": a partition's topic is all before its last.
    if ((Invoke-Kafka 'kafka-reassign-partitions' ($conn + @('--list'))) -ne 0) { return }
    $parts = 0; $adding = 0; $removing = 0; $per = New-Map
    foreach ($l in ($script:out -split "`r?`n")) {
        if ($l -cnotmatch '^(\S+)-\d+: replicas: ') { continue }
        $t = $Matches[1]
        $parts++; $per[$t] = 1 + [int]$per[$t]
        if ($l -cmatch 'adding: ([\d,]+)') { $adding += @($Matches[1] -split ',' | Where-Object { $_ }).Count }
        if ($l -cmatch 'removing: ([\d,]+)') { $removing += @($Matches[1] -split ',' | Where-Object { $_ }).Count }
    }
    Write-Output "metric partitions $parts"
    Write-Output "metric adding_replicas $adding"
    Write-Output "metric removing_replicas $removing"
    Write-Output "metric topics $($per.Count)"
    $n = 0
    foreach ($t in $per.Keys) { if (++$n -le 100) { Write-Output "metric topic_partitions $($per[$t]) topic=$t" } }
