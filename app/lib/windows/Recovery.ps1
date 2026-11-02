#Requires -Version 5.1

# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.

<#
.SYNOPSIS
    Vigil recovery conclusions - Windows PowerShell 5.1 compatible.
.DESCRIPTION
    Decides, from the evidence the supervisor gathered about a job's latest
    run, what that run is (SPECIFICATION.md 11.3). A pure function of its
    inputs. Must produce exactly the same result as recovery.sh -
    tests/conformance/recovery holds the shared table.

    Get-VigilRecoveryConclusion -Launch <none|held|young|old|prevboot>
        -Token <none|held|free> -Process <yes|no|error|-> -Boot <same|changed>
        -State <running|final|unreadable|missing> -Spool <yes|no>
    returns idle, alive, launching, abandon, finished, crashed or
    uncertain; recovery.sh documents each.
#>

function Get-VigilRecoveryConclusion {
    param([string]$Launch, [string]$Token, [string]$Process, [string]$Boot, [string]$State, [string]$Spool)

    switch -CaseSensitive ($Launch) {
        'held' { return 'alive' }
        'prevboot' { return 'abandon' }
        'young' { return 'launching' }
        'old' {
            if ($Process -ceq 'yes') { return 'launching' }
            if ($Process -ceq 'no') { return 'abandon' }
            return 'uncertain'
        }
    }

    # No launch in progress. Without a token, a final or missing state
    # leaves nothing to account for.
    if ($Token -ceq 'none' -and ($State -ceq 'final' -or $State -ceq 'missing')) { return 'idle' }

    # Nothing from an earlier boot can still be alive.
    if ($Boot -ceq 'changed') {
        if ($State -ceq 'final' -or $Spool -ceq 'yes') { return 'finished' }
        return 'crashed'
    }

    if ($Token -ceq 'held' -or $Process -ceq 'yes') { return 'alive' }
    if ($Process -ceq 'error') { return 'uncertain' }
    if ($State -ceq 'final' -or $Spool -ceq 'yes') { return 'finished' }
    return 'crashed'
}
