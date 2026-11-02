# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# Vigil data format (SPECIFICATION.md 18.7).
#
# state\format holds one number for everything under state\ and spool\,
# cursors and checkpoints included. An install from before it has none, which
# is format 1. A format change is a numbered script in app\migrations: N.ps1
# moves the data from N-1 to N, and the highest N is the format this version
# writes. The twin of this file is format.sh.

# Runs a script in a new process of this PowerShell, stderr captured.
function Invoke-VigilChild {
    param([string[]]$Arguments)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Process -Id $PID).Path
    $psi.Arguments = (@('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File') + @($Arguments | ForEach-Object { "`"$_`"" })) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEnd()
    [void]$out.Wait()
    $p.WaitForExit()
    return @{ Code = $p.ExitCode; Error = $err.Trim() }
}

function Get-VigilFormatCurrent {
    param([string]$App)
    $current = 1
    $dir = Join-Path $App 'migrations'
    if (-not [System.IO.Directory]::Exists($dir)) { return $current }
    foreach ($f in [System.IO.Directory]::GetFiles($dir, '*.ps1')) {
        $n = [System.IO.Path]::GetFileNameWithoutExtension($f)
        if ($n -cmatch '^[0-9]+$' -and [int]$n -gt $current) { $current = [int]$n }
    }
    return $current
}

# Refuses data it cannot read, or that a newer version wrote: guessing at it
# is how a downgrade would corrupt it.
function Test-VigilFormat {
    param([string]$App, [string]$State)
    $r = @{ Ok = $true; Stored = 1; Current = (Get-VigilFormatCurrent -App $App); Error = '' }
    $file = Join-Path $State 'format'
    if (-not [System.IO.File]::Exists($file)) { return $r }
    $text = [System.IO.File]::ReadAllText($file).Trim()
    if ($text -cnotmatch '^[0-9]+$') {
        $r.Ok = $false
        $r.Error = "$file is not a format number"
        return $r
    }
    $r.Stored = [int]$text
    if ($r.Stored -gt $r.Current) {
        $r.Ok = $false
        $r.Error = "the data is format $($r.Stored), newer than the format $($r.Current) this version reads; nothing was changed"
    }
    return $r
}

# Brings the data to this version's format, one step at a time. The number
# moves after each step, so a failed step is the one retried. The caller
# holds the supervisor lock.
function Invoke-VigilFormatMigrate {
    param([string]$App, [string]$State, [string]$Spool, [string]$Logs)
    $r = Test-VigilFormat -App $App -State $State
    if (-not $r.Ok) { return $r }
    $file = Join-Path $State 'format'
    $n = $r.Stored
    if (-not [System.IO.File]::Exists($file)) { Write-VigilFileAtomic -Path $file -Text "$n`n" }
    while ($n -lt $r.Current) {
        $n++
        $script = Join-Path $App "migrations\$n.ps1"
        if (-not [System.IO.File]::Exists($script)) {
            return @{ Ok = $false; Error = "migration $n is missing; the data stays at format $($n - 1)" }
        }
        $c = Invoke-VigilChild -Arguments @($script, $State, $Spool, $Logs)
        if ($c.Code -ne 0) {
            return @{ Ok = $false; Error = "migration $n failed; the data stays at format $($n - 1)" }
        }
        Write-VigilFileAtomic -Path $file -Text "$n`n"
    }
    return @{ Ok = $true; Error = '' }
}
