#Requires -Version 5.1

<#
.SYNOPSIS
    leases.ps1 - the leases and tokens an OpenBao or Vault node holds, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports the leases the node holds and those it could not revoke, the tokens
    created and by which auth method, and the mounts. Leases that grow without
    end make every restart and every failover slower; irrevocable ones are
    secrets that should have been revoked and were not. The active node holds
    them: on a standby these read 0. It only reads: every request is a GET, and
    it changes nothing.

    Reads OPENBAO_URL (default http://localhost:8200):
    /v1/sys/metrics?format=prometheus, with OPENBAO_TOKEN.
    What the scripts share is in _openbao.ps1, beside this one.

    Metrics:
      up                        1 when OpenBao answered its metrics page, else 0
                                (and nothing more is read)
      leases                    leases held, tokens' included
      irrevocable_leases        leases it tried to revoke and could not
      tokens_created_count      tokens created (a running total)
      tokens_created            the same, for each auth method, tagged
                                method=<token, userpass, approle, kubernetes
                                ...>
      tokens_created_not_shown  how many more there were than the 20 shown
      tokens                    tokens (Vault, every usage_gauge_period: 10
                                minutes by default)
      mounts                    mounts: secrets engines and auth methods

    Example output (the rest are in the same form):
      (draft: no example yet)

    Reading the results (starting points: tune them to your own):
      Healthy  leases steady with the workload; irrevocable_leases 0.
      Watch    leases growing day after day: long TTLs, or clients that log in
               again and again without reusing their token (tokens_created says
               by which method).
      Act      irrevocable_leases above 0: credentials it could not revoke, in a
               database or a cloud account, still work: find them (sys/leases)
               and revoke them where they live; leases in the hundreds of
               thousands: restarts and failovers slow down, and storage grows.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0, whatever it reads, and when OpenBao does not answer (up 0 is
      the reading); 1 when it answers wrong (a login refused, not HTTP), said on
      stderr
#>

$Job = 'leases'
. (Join-Path $PSScriptRoot '_openbao.ps1')

Read-Page '/v1/sys/metrics?format=prometheus'
Get-Readings @'
leases|max|vault_expire_num_leases
irrevocable_leases|max?|vault_expire_num_irrevocable_leases
tokens_created_count|sum?|vault_token_creation
tokens_created|by|vault_token_creation||auth_method:method
tokens|max?|vault_token_count
mounts|sum?|vault_core_mount_table_num_entries
'@
exit 0
