#Requires -Version 5.1

<#
.SYNOPSIS
    install.ps1 - installs or upgrades Vigil on Windows (SPECIFICATION.md 18.7).
.DESCRIPTION
    With the defaults (system mode from an elevated prompt, user mode
    otherwise):

        [Net.ServicePointManager]::SecurityProtocol = 'Tls12'; irm https://github.com/godspeedhq/vigil/releases/latest/download/install.ps1 | iex

    With options:

        & ([scriptblock]::Create((irm https://github.com/godspeedhq/vigil/releases/latest/download/install.ps1))) -System -Backend datadog

    Or the reviewed way: download the release zip and SHA256SUMS, check
    them, read this file, and run it with -Archive.

    Steps: check the prerequisites, download the archive and verify its
    SHA-256 before using it, unpack it into the root (on upgrade only app\
    and vendor\ are replaced; config\ and scripts\ are never touched), clear
    the downloaded-from-the-internet mark, add app\ to the PATH, run vigil
    init on a fresh install, register the service.
.PARAMETER User
    User mode: %LOCALAPPDATA%\Vigil, a Run entry at logon, no admin.
.PARAMETER System
    System mode: C:\ProgramData\Vigil, an NSSM service. Needs an elevated prompt.
.PARAMETER Prefix
    Another install root.
.PARAMETER Version
    A release (default: the latest).
.PARAMETER Archive
    Install this vigil-<version>.zip instead of downloading it; SHA256SUMS must be beside it.
.PARAMETER ShellHost
    powershell (Windows PowerShell 5.1, the default) or pwsh (PowerShell 7): what the service runs on.
.PARAMETER Instance
    Passed to vigil init.
.PARAMETER Backend
    Passed to vigil init (file, datadog, otel).
.PARAMETER NoInit
    Do not write a starting configuration.
.PARAMETER NoService
    Do not register the service.
#>

param(
    [switch]$User,
    [switch]$System,
    [string]$Prefix,
    [string]$Version,
    [string]$Archive,
    [ValidateSet('powershell', 'pwsh')][string]$ShellHost = 'powershell',
    [string]$Instance,
    [string]$Backend,
    [switch]$NoInit,
    [switch]$NoService
)

# Restored at the end, for the same reason.
$savedPreferences = @($ErrorActionPreference, $ProgressPreference)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$repoUrl = 'https://github.com/godspeedhq/vigil'

# Never exit: under irm | iex this runs in the caller's own session, which
# exit would close. A failure throws instead.
function Stop-Install {
    param([string]$Message)
    throw "install: $Message"
}

# PowerShell 5.1 on older servers may not offer TLS 1.2 by default.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$admin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if ($User -and $System) { Stop-Install 'choose -User or -System, not both' }
$mode = if ($System) { 'system' } elseif ($User) { 'user' } elseif ($admin) { 'system' } else { 'user' }
if ($mode -ceq 'system' -and -not $admin) { Stop-Install 'system mode needs an elevated prompt; or use -User' }
$root = if ($Prefix) { $Prefix } elseif ($mode -ceq 'system') { Join-Path $env:ProgramData 'Vigil' } else { Join-Path $env:LOCALAPPDATA 'Vigil' }
$root = [System.IO.Path]::GetFullPath($root)

# --- 1. Prerequisites (5.1), before anything changes ------------------------

if ($PSVersionTable.PSVersion -lt [Version]'5.1') { Stop-Install "Windows PowerShell 5.1 or later is required (this is $($PSVersionTable.PSVersion))" }
if (-not $NoService -and $ShellHost -ceq 'pwsh' -and -not (Get-Command -Name 'pwsh.exe' -CommandType Application -ErrorAction SilentlyContinue)) {
    Stop-Install 'PowerShell 7 (pwsh) is not installed; install it, or use -ShellHost powershell'
}

# --- 2. The archive, verified ---------------------------------------------------

$work = Join-Path ([System.IO.Path]::GetTempPath()) "vigil-install.$PID"
[void](New-Item -ItemType Directory -Force -Path $work)
try {
    if ($Archive) {
        if (-not (Test-Path -LiteralPath $Archive -PathType Leaf)) { Stop-Install "no archive at $Archive" }
        $file = Split-Path -Leaf $Archive
        $sums = Join-Path (Split-Path -Parent (Resolve-Path -LiteralPath $Archive).ProviderPath) 'SHA256SUMS'
        if (-not (Test-Path -LiteralPath $sums)) { Stop-Install "no SHA256SUMS beside $Archive`: the archive cannot be verified" }
        Copy-Item -LiteralPath $Archive -Destination (Join-Path $work $file)
        Copy-Item -LiteralPath $sums -Destination (Join-Path $work 'SHA256SUMS')
    }
    else {
        if (-not $Version) {
            try { $Version = ([string](Invoke-RestMethod -UseBasicParsing -Uri 'https://api.github.com/repos/godspeedhq/vigil/releases/latest').tag_name).TrimStart('v') }
            catch { Stop-Install "cannot reach GitHub to find the latest release: $($_.Exception.Message)" }
        }
        $Version = $Version.TrimStart('v')
        $file = "vigil-$Version.zip"
        Write-Output "downloading Vigil $Version"
        try {
            Invoke-WebRequest -UseBasicParsing -Uri "$repoUrl/releases/download/v$Version/$file" -OutFile (Join-Path $work $file)
            Invoke-WebRequest -UseBasicParsing -Uri "$repoUrl/releases/download/v$Version/SHA256SUMS" -OutFile (Join-Path $work 'SHA256SUMS')
        }
        catch { Stop-Install "cannot download Vigil $Version`: $($_.Exception.Message)" }
    }
    $want = ''
    foreach ($l in [System.IO.File]::ReadAllLines((Join-Path $work 'SHA256SUMS'))) {
        $f = $l -split '\s+', 2
        if ($f.Count -eq 2 -and $f[1].TrimStart('*') -ceq $file) { $want = $f[0].ToLowerInvariant() }
    }
    if (-not $want) { Stop-Install "SHA256SUMS has no entry for $file" }
    $got = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $work $file)).Hash.ToLowerInvariant()
    if ($got -cne $want) { Stop-Install "SHA-256 mismatch for $file`: expected $want, got $got; nothing was changed" }
    Write-Output "verified $file (SHA-256 $got)"

    $x = Join-Path $work 'x'
    Expand-Archive -LiteralPath (Join-Path $work $file) -DestinationPath $x
    $src = @(Get-ChildItem -LiteralPath $x -Directory)[0].FullName
    if (-not (Test-Path -LiteralPath (Join-Path $src 'app\vigil.ps1'))) { Stop-Install "$file does not hold a Vigil release" }
    # Verified: the downloaded-from-the-internet mark would make a
    # RemoteSigned policy refuse Vigil's scripts.
    Get-ChildItem -LiteralPath $src -Recurse -File | Unblock-File
    $verFile = Join-Path $src 'app\VERSION'
    if (Test-Path -LiteralPath $verFile) { $Version = ([System.IO.File]::ReadAllText($verFile)).Trim() }

    # --- 3. Unpack into the root ----------------------------------------------------

    $vigil = Join-Path $root 'app\vigil.ps1'
    $upgrade = Test-Path -LiteralPath $vigil
    [void](New-Item -ItemType Directory -Force -Path $root)
    $running = $false
    $self = (Get-Process -Id $PID).Path
    if ($upgrade -and -not $NoService) {
        $st = & $self -NoProfile -ExecutionPolicy Bypass -File $vigil -Root $root status 2>$null | Select-Object -First 1
        if ("$st".StartsWith('service: active')) {
            $running = $true
            & $self -NoProfile -ExecutionPolicy Bypass -File $vigil -Root $root stop | Out-Null
            if ($LASTEXITCODE -ne 0) { Stop-Install 'cannot stop the running service for the upgrade' }
        }
    }
    foreach ($d in @('app', 'vendor')) {
        $to = Join-Path $root $d
        $old = Join-Path $root "$d.old"
        if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Recurse -Force }
        if (Test-Path -LiteralPath $to) { Rename-Item -LiteralPath $to -NewName "$d.old" }
        Copy-Item -LiteralPath (Join-Path $src $d) -Destination $to -Recurse
        if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction SilentlyContinue }
    }
    if ($upgrade) { Write-Output "upgraded $root to Vigil $Version" } else { Write-Output "installed Vigil $Version in $root" }

    # --- 4. The vigil command: app\ on the PATH ---------------------------------------

    $app = Join-Path $root 'app'
    $scope = if ($mode -ceq 'system') { 'Machine' } else { 'User' }
    $path = [Environment]::GetEnvironmentVariable('Path', $scope)
    if (-not (@("$path".Split(';') | Where-Object { $_.TrimEnd('\') -ieq $app }).Count)) {
        [Environment]::SetEnvironmentVariable('Path', (@(@("$path".Split(';') | Where-Object { $_ }) + $app) -join ';'), $scope)
        Write-Output "added $app to the $($scope.ToLowerInvariant()) PATH: new consoles run vigil"
    }

    function Invoke-Vigil { & $self -NoProfile -ExecutionPolicy Bypass -File $vigil -Root $root @args }

    # --- 5. vigil init, on a fresh install ----------------------------------------------

    if (-not $NoInit -and -not (Test-Path -LiteralPath (Join-Path $root 'config\vigil.config'))) {
        $a = @('init')
        if ($Instance) { $a += @('--instance', $Instance) }
        if ($Backend) { $a += @('--backend', $Backend) }
        Write-Output ''
        Invoke-Vigil @a
        if ($LASTEXITCODE -ne 0) { Stop-Install 'vigil init failed' }
    }

    # --- 6. The service ---------------------------------------------------------------------

    if (-not $NoService) {
        Write-Output ''
        $st = Invoke-Vigil status 2>$null | Select-Object -First 1
        if ($upgrade -and -not "$st".StartsWith('service: not registered')) {
            if ($running) {
                Invoke-Vigil start | Out-Null
                if ($LASTEXITCODE -ne 0) { Stop-Install 'the service did not start again after the upgrade' }
            }
        }
        else {
            Invoke-Vigil service install "--$mode" --host $ShellHost
            if ($LASTEXITCODE -ne 0) {
                Write-Output ''
                Write-Output 'Vigil is installed but not running: fix what the checks above report'
                Write-Output "(edit $root\config\vigil.config, set the environment), then run: vigil service install --$mode --host $ShellHost"
                Stop-Install 'the service was not registered'
            }
        }
    }
    Write-Output ''
    Write-Output "done: Vigil $Version. vigil status shows what it is doing."
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    $ErrorActionPreference, $ProgressPreference = $savedPreferences
}
