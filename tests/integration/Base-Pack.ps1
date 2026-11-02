#Requires -Version 5.1

<#
.SYNOPSIS
    Integration test: the base pack on this machine (SPECIFICATION.md 18.10).
.DESCRIPTION
    vigil init turns it on, each job runs, and its metrics reach a backend.
    The twin of base-pack.sh.

    Exit code: 0 all passed, 1 any failed.
#>

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent (Split-Path -Parent $here)
$shell = (Get-Process -Id $PID).Path
$work = Join-Path ([System.IO.Path]::GetTempPath()) "vigil base.$PID"
$script:pass = 0
$script:fail = 0

function Test-Equal {
    param([string]$Name, [string]$Expected, [string]$Actual)
    if ($Expected -ceq $Actual) { $script:pass++; Write-Host "  PASS  $Name" }
    else { $script:fail++; Write-Host "  FAIL  ${Name}: expected [$Expected] actual [$Actual]" }
}

function Invoke-Vigil {
    $out = & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'app\vigil.ps1') -Root $root @args 2>&1
    return @{ Code = $LASTEXITCODE; Text = (@($out | ForEach-Object { "$_" }) -join "`n") }
}

function Test-Reports {
    param([string]$Metric)
    $f = "$root\metrics\vigil.prom"
    return [string]([System.IO.File]::Exists($f) -and [System.IO.File]::ReadAllText($f) -cmatch "(?m)^$Metric")
}

Write-Host "PowerShell $($PSVersionTable.PSVersion)"
[void](New-Item -ItemType Directory -Force -Path "$work\root\packs\base")
$work = (Resolve-Path -LiteralPath $work).ProviderPath
$root = "$work\root"

try {
    Copy-Item -Recurse -LiteralPath (Join-Path $repo 'app'), (Join-Path $repo 'vendor') -Destination $root
    Copy-Item -LiteralPath (Join-Path $repo 'packs\base\pack.config') -Destination "$root\packs\base"
    Get-ChildItem -LiteralPath (Join-Path $repo 'packs\base\windows') -File | Copy-Item -Destination "$root\packs\base"

    $r = Invoke-Vigil init --instance base --backend file
    Test-Equal 'init turns on the base pack' '0' ([string]$r.Code)
    Test-Equal 'precheck is happy' '0' ([string](Invoke-Vigil precheck).Code)
    Test-Equal 'no load job: Windows has no load average' 'False' ([string](Test-Path -LiteralPath "$root\packs\base\load.ps1"))

    foreach ($j in @('cpu', 'memory', 'disk', 'network', 'services')) {
        $r = Invoke-Vigil run "base_$j"
        Test-Equal "base_$j runs" '0' ([string]$r.Code)
        if ($r.Code -ne 0) { $r.Text.Split("`n") | ForEach-Object { Write-Host "        $_" } }
    }

    # The sender delivers from the spool.
    foreach ($i in 1..3) {
        [void](Invoke-Vigil supervise --once)
        Start-Sleep -Seconds 3
    }
    Test-Equal 'CPU reaches the backend' 'True' (Test-Reports 'system_cpu_used_pct')
    Test-Equal 'memory reaches the backend' 'True' (Test-Reports 'system_memory_used_pct')
    Test-Equal 'disk reaches the backend' 'True' (Test-Reports 'system_disk_used_pct')
    Test-Equal 'network reaches the backend' 'True' (Test-Reports 'system_network_rx_bytes')
}
finally {
    Start-Sleep -Seconds 2
    Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
}

Write-Host "$($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
