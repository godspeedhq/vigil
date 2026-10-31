#Requires -Version 5.1

<#
.SYNOPSIS
    Integration test: service registration (SPECIFICATION.md 18) on Windows.
.DESCRIPTION
    System mode (needs an elevated prompt, as on CI runners): the NSSM
    service, with Windows PowerShell 5.1 and, when installed, PowerShell 7
    as the host. User mode: the per-user Run entry. Registers for real,
    checks that a running job outlives "vigil stop" and "vigil service
    remove", and that failing pre-flight checks register nothing. The twin
    of service.sh.

    It changes the machine: run it on a CI runner or a throwaway VM.

    Exit code: 0 all passed, 1 any failed.
#>

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent (Split-Path -Parent $here)
$shell = (Get-Process -Id $PID).Path
$script:pass = 0
$script:fail = 0

function Test-Equal {
    param([string]$Name, [string]$Expected, [string]$Actual)
    if ($Expected -ceq $Actual) { $script:pass++; Write-Host "  PASS  $Name" }
    else { $script:fail++; Write-Host "  FAIL  ${Name}: expected [$Expected] actual [$Actual]" }
}

function Invoke-Vigil {
    param([string]$Root, [string[]]$Arguments)
    $out = & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'app\vigil.ps1') -Root $Root @Arguments 2>&1
    $script:lastOut = ($out | ForEach-Object { "$_" }) -join "`n"
    return $LASTEXITCODE
}

# active, inactive or not registered, from the first line of vigil status.
function Get-SvcState {
    param([string]$Root)
    [void](Invoke-Vigil $Root @('status'))
    $first = ($script:lastOut -split "`n")[0]
    if ($first -cmatch '^service: ([a-z ]*)') { return $Matches[1].TrimEnd() }
    return $first
}

function Get-StateValue {
    param([string]$Path, [string]$Key)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    foreach ($l in [System.IO.File]::ReadAllLines($Path)) {
        if ($l -cmatch "^$Key *=( (.*))?$") { return $Matches[2] }
    }
    return ''
}

function Test-Alive {
    param([string]$ProcessId)
    if (-not $ProcessId) { return 'no pid' }
    return "$([bool](Get-Process -Id ([int]$ProcessId) -ErrorAction SilentlyContinue))"
}

# An install root: the app, NSSM, a job that holds on for five minutes and
# a configuration.
function New-Root {
    param([string]$Root)
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $Root 'config'), (Join-Path $Root 'scripts'))
    Copy-Item -Recurse -LiteralPath (Join-Path $repo 'app') -Destination $Root
    Copy-Item -Recurse -LiteralPath (Join-Path $repo 'vendor') -Destination $Root
    [System.IO.File]::WriteAllText((Join-Path $Root 'scripts\hold.cmd'), "@echo off`r`nping -n 300 127.0.0.1 > nul`r`n")
    [System.IO.File]::WriteAllText((Join-Path $Root 'config\vigil.config'), @"
[vigil]
instance = service-it

[scheduler]
tick = 1s

[job.hold]
file      = scripts\hold.cmd
run_every = 2s
"@)
}

# The lifecycle in one mode and host.
function Test-Lifecycle {
    param([string]$Mode, [string]$Root, [string]$HostName, [string]$HostExe)
    $tag = "$Mode/$HostName"
    Write-Host "$tag, root $Root"
    $rc = Invoke-Vigil $Root @('service', 'install', "--$Mode", '--host', $HostName)
    Test-Equal "${tag}: service install succeeds" '0' "$rc"
    if ($rc -ne 0) { Write-Host $script:lastOut }
    Test-Equal "${tag}: the service is active" 'active' (Get-SvcState $Root)

    $st = Join-Path $Root 'state\jobs\hold.state'
    for ($i = 0; $i -lt 120 -and -not (Get-StateValue $st 'job_pid'); $i++) { Start-Sleep -Milliseconds 500 }
    $worker = Get-StateValue $st 'worker_pid'
    $job = Get-StateValue $st 'job_pid'
    Test-Equal "${tag}: the supervisor started the job" 'True' "$([bool]$job)"
    if (-not $job) {
        [void](Invoke-Vigil $Root @('status')); Write-Host $script:lastOut
        Get-Content -LiteralPath (Join-Path $Root 'logs\supervisor\service.log') -ErrorAction SilentlyContinue
        [void](Invoke-Vigil $Root @('service', 'remove'))
        return
    }
    $wp = Get-Process -Id ([int]$worker) -ErrorAction SilentlyContinue
    Test-Equal "${tag}: the worker runs on the chosen host" $HostExe "$(if ($wp) { $wp.Path })"

    Test-Equal "${tag}: stop succeeds" '0' "$(Invoke-Vigil $Root @('stop'))"
    Test-Equal "${tag}: the service is inactive after stop" 'inactive' (Get-SvcState $Root)
    Test-Equal "${tag}: the worker outlives stop" 'True' (Test-Alive $worker)
    Test-Equal "${tag}: the job outlives stop" 'True' (Test-Alive $job)
    $log = Join-Path $Root 'logs\supervisor'
    $stopped = @(Get-ChildItem -LiteralPath $log -Filter '*.log' | Where-Object { $_.Name -match '^\d{4}-' } |
            Select-String -SimpleMatch 'supervisor stopped; running workers continue').Count
    if ($Mode -ceq 'system') { Test-Equal "${tag}: the supervisor stopped gracefully" 'True' "$($stopped -gt 0)" }

    Test-Equal "${tag}: start succeeds" '0' "$(Invoke-Vigil $Root @('start'))"
    Test-Equal "${tag}: the service is active after start" 'active' (Get-SvcState $Root)
    Test-Equal "${tag}: restart succeeds" '0' "$(Invoke-Vigil $Root @('restart'))"
    Test-Equal "${tag}: the service is active after restart" 'active' (Get-SvcState $Root)

    Test-Equal "${tag}: service remove succeeds" '0' "$(Invoke-Vigil $Root @('service', 'remove'))"
    Test-Equal "${tag}: the service is gone" 'not registered' (Get-SvcState $Root)
    Test-Equal "${tag}: the job outlives remove" 'True' (Test-Alive $job)
    Test-Equal "${tag}: removing again changes nothing" '0' "$(Invoke-Vigil $Root @('service', 'remove'))"

    # Test cleanup: these are the test's own processes.
    foreach ($p in @($job, $worker)) { Stop-Process -Id ([int]$p) -Force -ErrorAction SilentlyContinue }
}

Write-Host "PowerShell $($PSVersionTable.PSVersion)"
$admin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
$tmp = [System.IO.Path]::GetTempPath()
$ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

if (-not $admin) {
    Write-Host 'SKIP system mode: needs an elevated prompt'
}
else {
    # Failing pre-flight checks register nothing.
    $bad = Join-Path $tmp "vigil-svc-bad.$PID"
    New-Root $bad
    [System.IO.File]::AppendAllText((Join-Path $bad 'config\vigil.config'), "`n[job.broken]`nrun_every = 1h`n")
    Test-Equal 'system: install with failing pre-flight checks is refused' '1' "$(Invoke-Vigil $bad @('service', 'install', '--system'))"
    Test-Equal 'system: and registers nothing' 'not registered' (Get-SvcState $bad)
    Remove-Item -Recurse -Force -LiteralPath $bad

    $root = Join-Path $tmp "vigil-svc.$PID"
    New-Root $root
    Test-Lifecycle 'system' $root 'powershell' $ps51
    $acl = Get-Acl -LiteralPath $root
    Test-Equal 'system: the root does not inherit access' 'True' "$($acl.AreAccessRulesProtected)"
    $who = @($acl.Access | ForEach-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } | Sort-Object -Unique) -join ','
    Test-Equal 'system: only SYSTEM and Administrators have access' 'S-1-5-18,S-1-5-32-544' $who

    $pwsh = @(Get-Command -Name 'pwsh.exe' -CommandType Application -ErrorAction SilentlyContinue)
    if ($pwsh.Count -gt 0) { Test-Lifecycle 'system' $root 'pwsh' $pwsh[0].Source }
    else { Write-Host 'SKIP system/pwsh: PowerShell 7 is not installed' }
    Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue
}

Test-Equal 'an unknown host is refused' '1' "$(Invoke-Vigil $repo @('service', 'install', '--user', '--host', 'cmd'))"

$root = Join-Path $tmp "vigil svc user.$PID"
New-Root $root
Test-Lifecycle 'user' $root 'powershell' $ps51
$pwsh = @(Get-Command -Name 'pwsh.exe' -CommandType Application -ErrorAction SilentlyContinue)
if ($pwsh.Count -gt 0) { Test-Lifecycle 'user' $root 'pwsh' $pwsh[0].Source }
Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue

Write-Host "$script:pass passed, $script:fail failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
