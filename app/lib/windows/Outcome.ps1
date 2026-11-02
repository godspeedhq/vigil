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
    Vigil run outcomes - Windows PowerShell 5.1 compatible.
.DESCRIPTION
    Classifies a finished job's exit code by its exit_codes setting
    (SPECIFICATION.md 10.2). A pure function of its inputs. Must produce
    exactly the same result as outcome.sh - tests/conformance/outcome holds
    the shared table.

    Get-VigilOutcome -ExitCodes <standard|nagios|list> -Code <exit code>
    returns succeeded, warning, failed, unknown, or error for malformed
    input. The code may be negative or above 255, as Windows exit codes can
    be.
#>

function Get-VigilOutcome {
    param([string]$ExitCodes, [string]$Code)

    if ($Code -cnotmatch '^-?[0-9]{1,10}$') { return 'error' }
    $c = [long]$Code

    if ($ExitCodes -ceq 'standard') {
        if ($c -eq 0) { return 'succeeded' }
        return 'failed'
    }
    if ($ExitCodes -ceq 'nagios') {
        switch ($c) {
            0 { return 'succeeded' }
            1 { return 'warning' }
            2 { return 'failed' }
        }
        return 'unknown'
    }

    # A list: succeeded when the code is listed, failed otherwise.
    $outcome = 'failed'
    foreach ($item in $ExitCodes.Split(',')) {
        # Items may carry spaces around the comma.
        $item = $item.Replace(' ', '').Replace("`t", '')
        if ($item -cnotmatch '^([0-9]{1,3})(-([0-9]{1,3}))?$') { return 'error' }
        $lo = [int]$Matches[1]
        $hi = $lo
        if ($Matches[3]) { $hi = [int]$Matches[3] }
        if ($c -ge $lo -and $c -le $hi) { $outcome = 'succeeded' }
    }
    return $outcome
}
