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

    # The ACLs, the users with SCRAM credentials, and the quotas: counts only,
    # never a principal's or a client's name. An ACL is a line under its
    # resource pattern:
    #   Current ACLs for resource `ResourcePattern(resourceType=TOPIC, name=*, patternType=LITERAL)`:
    #       (principal=User:app, host=*, operation=READ, permissionType=ALLOW)
    # With no authorizer, the cluster says so: authorizer 0, and no ACL counts.
    $rc = Invoke-Kafka 'kafka-acls' ($conn + @('--list')) -Soft
    if ($rc -eq 2) { return }
    if ($rc -eq 0) {
        Write-Output 'metric authorizer 1'
        $res = ''; $n = 0; $wild = 0; $all = 0; $by = New-Map
        foreach ($l in ($script:out -split "`r?`n")) {
            if ($l -cmatch 'resourceType=([A-Z_]+)') { $res = $Matches[1].ToLowerInvariant() }
            if ($l -cnotmatch '\(principal=') { continue }
            $n++
            $p = if ($l -cmatch 'permissionType=DENY') { 'deny' } else { 'allow' }
            $k = "resource=$res permission=$p"; $by[$k] = 1 + [int]$by[$k]
            if ($l -cmatch 'principal=User:\*,') { $wild++ }
            if ($l -cmatch 'operation=ALL,') { $all++ }
        }
        Write-Output "metric all_acls $n"
        Write-Output "metric any_principal_acls $wild"
        Write-Output "metric all_operations_acls $all"
        foreach ($k in $by.Keys) { Write-Output "metric acls $($by[$k]) $k" }
    }
    elseif ($script:err -match 'SecurityDisabledException|No Authorizer') { Write-Output 'metric authorizer 0' }
    else { Stop-Run "kafka-acls failed: $(Get-Why $script:err)" }
    if ((Invoke-Kafka 'kafka-configs' ($conn + @('--describe', '--entity-type', 'users'))) -ne 0) { return }
    $scram = @($script:out -split "`r?`n" | Where-Object { $_ -cmatch '^SCRAM credential configs for user-principal ' }).Count
    $q = @($script:out -split "`r?`n" | Where-Object { $_ -cmatch '^Quota configs for user-principal ' }).Count
    Write-Output "metric scram_users $scram"
    Write-Output "metric quotas $q entity=user"
    if ((Invoke-Kafka 'kafka-configs' ($conn + @('--describe', '--entity-type', 'clients'))) -ne 0) { return }
    $q = @($script:out -split "`r?`n" | Where-Object { $_ -cmatch '^Quota configs for client-id ' }).Count
    Write-Output "metric quotas $q entity=client"
