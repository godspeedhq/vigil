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

    # The brokers, as the cluster lists them.
    if ((Invoke-BrokersList) -eq 2) { Write-Output 'metric up 0'; return }
    $brokers = $script:out

    # KRaft: the quorum names the cluster and its active controller. A cluster
    # on ZooKeeper (Kafka 3) has no quorum to ask: its id comes from
    # kafka-cluster.
    $kraft = 'yes'; $cluster = ''; $controller = ''
    $rc = Invoke-Kafka 'kafka-metadata-quorum' ($conn + @('describe', '--status')) -Soft
    if ($rc -eq 2) { Write-Output 'metric up 0'; return }
    if ($rc -eq 0) {
        foreach ($l in ($script:out -split "`r?`n")) {
            if ($l -cmatch '^ClusterId:\s*(\S+)') { $cluster = $Matches[1] }
            elseif ($l -cmatch '^LeaderId:\s*(-?\d+)') { $controller = $Matches[1] }
        }
    }
    if (-not $cluster) {
        $kraft = 'no'
        if ((Invoke-Kafka 'kafka-cluster' (@('cluster-id') + $conn)) -eq 2) { Write-Output 'metric up 0'; return }
        if ($script:out -cmatch 'Cluster ID:\s*(\S+)') { $cluster = $Matches[1] }
    }

    Write-Output 'metric up 1'
    Write-Output "metric info 1 cluster_id=$(ConvertTo-Tag $cluster) kraft=$kraft"
    $n = 0; $fenced = 0
    foreach ($l in ($brokers -split "`r?`n")) {
        if ($l -cmatch ' \(id: \d+ rack: ') { $n++; if ($l -cmatch 'isFenced: true') { $fenced++ } }
    }
    Write-Output "metric brokers $n"
    Write-Output "metric brokers_fenced $fenced"
    if ($controller -and $controller -cne '-1') { Write-Output "metric controller_id $controller" }
