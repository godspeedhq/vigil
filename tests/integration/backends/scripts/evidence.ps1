# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.

# evidence.ps1 - the twin of common.sh's evidence_start and evidence_save,
# dot-sourced by run-store.ps1, run-source.ps1 and run-vigil.ps1. What a run
# printed, and Vigil's own record of it, kept in
# reports\runs\<date>\<host>\<name>\ for the compatibility reports:
#   console.txt  a header (when, where, which Vigil, which tools and
#                images), then everything the run printed (a transcript)
#   *.out        what Vigil printed
#   root\        Vigil's config, logs, state and metrics, as the run left them
# VIGIL_EVIDENCE_HOST names the host (default: its name, lower case).

# Once $work and $root are set; $Bk is the backends folder.
function Start-Evidence {
    param([string]$Name, [string]$Bk, [string]$Compose, [string]$Command)
    $h = if ($env:VIGIL_EVIDENCE_HOST) { $env:VIGIL_EVIDENCE_HOST } else { $env:COMPUTERNAME.ToLowerInvariant() }
    $script:evDir = Join-Path $Bk "reports\runs\$([DateTime]::UtcNow.ToString('yyyy-MM-dd'))\$h\$Name"
    $script:evBk = $Bk
    Remove-Item -LiteralPath $script:evDir -Recurse -Force -ErrorAction SilentlyContinue
    [void](New-Item -ItemType Directory -Force -Path $script:evDir)
    $repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $Bk))
    # VIGIL_EVIDENCE_COMMIT, when a copy of a commit was put here.
    if ($env:VIGIL_EVIDENCE_COMMIT) { $rev = "$env:VIGIL_EVIDENCE_COMMIT (deployed copy)" }
    else {
        $rev = & git -C $repo rev-parse HEAD 2> $null
        if ($LASTEXITCODE -ne 0 -or -not $rev) { $rev = 'unknown: not a Git checkout' }
        elseif (& git -C $repo status --porcelain -- app tests 2> $null) { $rev = "$rev, with local changes" }
    }
    $os = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    # Windows 11 still calls itself Windows 10 there; its build says which.
    $osName = if ([int]$os.CurrentBuild -ge 22000) { $os.ProductName -replace '^Windows 10', 'Windows 11' } else { $os.ProductName }
    $version = { param([string]$Exe, [string[]]$A) try { "$(@(& $Exe @A 2>&1 | ForEach-Object { "$_" })[0])" } catch { 'none' } }
    $lines = @(
        "== $Name"
        "date     $([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
        "host     $env:COMPUTERNAME"
        "os       $osName $($os.DisplayVersion) (build $($os.CurrentBuild).$($os.UBR))"
        "vigil    $rev"
        "command  $Command"
        "shell    PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
        "git      $(& $version git @('--version'))"
        "curl     $(& $version curl.exe @('--version'))"
        "ssh      $(& $version ssh @('-V'))"
        "images   (as $Compose pins them)")
    foreach ($f in @(Get-ChildItem -Path (Join-Path $Bk $Compose) -ErrorAction SilentlyContinue)) {
        foreach ($l in [System.IO.File]::ReadAllLines($f.FullName)) { if ($l -match '^\s*image:\s*(\S+)') { $lines += "         $($Matches[1])" } }
    }
    $lines = @($lines | Select-Object -Unique)
    [void](Start-Transcript -LiteralPath (Join-Path $script:evDir 'console.txt') -Force)
    $lines + '' | Write-Output
}

# In the finally block, before $work goes. A file holding any of $Values
# (the run's secrets and credentials) is left out, and said so: the run has
# failed its leak check already.
function Save-Evidence {
    param([string]$Work, [string]$Root, [string[]]$Values)
    if (-not $script:evDir -or -not (Test-Path -LiteralPath $script:evDir)) { return }
    $dest = Join-Path $script:evDir 'root'
    [void](New-Item -ItemType Directory -Force -Path $dest)
    foreach ($d in 'config', 'logs', 'state', 'metrics') {
        $p = Join-Path $Root $d
        if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination $dest -Recurse -Force }
    }
    Remove-Item -LiteralPath (Join-Path $dest 'state\locks') -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $Work -Filter '*.out' -File -ErrorAction SilentlyContinue | Copy-Item -Destination $script:evDir
    foreach ($f in @(Get-ChildItem -LiteralPath $script:evDir -Recurse -File | Where-Object { $_.Name -cne 'console.txt' })) {
        $text = try { [System.IO.File]::ReadAllText($f.FullName) } catch { '' }
        foreach ($x in $Values) {
            if ($x -and $text.Contains($x)) {
                Remove-Item -LiteralPath $f.FullName -Force
                Write-Output "evidence: $($f.FullName.Substring($script:evDir.Length + 1)) held a credential and was left out"
                break
            }
        }
    }
    Write-Output "evidence: $($script:evDir.Substring($script:evBk.Length + 1))"
    try { [void](Stop-Transcript) } catch { }
    # The transcript, checked once it is closed.
    $c = Join-Path $script:evDir 'console.txt'
    $text = try { [System.IO.File]::ReadAllText($c) } catch { '' }
    foreach ($x in $Values) { if ($x -and $text.Contains($x)) { Write-Output 'evidence: console.txt holds a credential: do not publish it'; break } }
}
