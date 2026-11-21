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

    # The cluster's finalized features against what its brokers support:
    #   Feature: metadata.version  SupportedMinVersion: 3.3-IV3  SupportedMaxVersion: 4.4-IV2  FinalizedVersionLevel: 4.4-IV2  Epoch: 594
    # A feature below the most its brokers support is one an upgrade has not
    # finalized yet (kafka-features upgrade). metadata.version is named; the
    # others are levels.
    if ((Invoke-Kafka 'kafka-features' ($conn + @('describe'))) -ne 0) { return }
    $n = 0; $total = 0
    foreach ($l in ($script:out -split "`r?`n")) {
        if ($l -cnotmatch '^Feature:\s*(\S+)') { continue }
        $f = $Matches[1]
        $mx = if ($l -cmatch 'SupportedMaxVersion:\s*(\S+)') { $Matches[1] } else { '' }
        $lv = if ($l -cmatch 'FinalizedVersionLevel:\s*(\S+)') { $Matches[1] } else { '-' }
        $behind = [int]($lv -cne $mx); $n++; $total += $behind
        if ($f -ceq 'metadata.version') { Write-Output "metric metadata_version 1 version=$lv supported=$mx" }
        elseif ($lv -cmatch '^\d+$' -and $mx -cmatch '^\d+$') {
            Write-Output "metric level $lv feature=$f"
            Write-Output "metric supported_level $mx feature=$f"
        }
        Write-Output "metric behind $behind feature=$f"
    }
    Write-Output "metric features $n"
    Write-Output "metric features_behind $total"
