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
    install.ps1 - installs or upgrades Vigil on Windows (SPECIFICATION.md 18.7).
.DESCRIPTION
    With the defaults (system mode from an elevated prompt, user mode
    otherwise):

        [Net.ServicePointManager]::SecurityProtocol = 'Tls12'; irm https://github.com/godspeedhq/vigil/releases/latest/download/install.ps1 | iex

    With options:

        & ([scriptblock]::Create((irm https://github.com/godspeedhq/vigil/releases/latest/download/install.ps1))) -System -Backend datadog

    Or the reviewed way: download the release zip, SHA256SUMS and
    SHA256SUMS.sig, read this file, and run it with -Archive and -Key.

    Steps: check the prerequisites, download the archive and verify its
    signature (when there is a key) and SHA-256 before using it, unpack it into the root (on upgrade only app\
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
    Install this vigil-<version>.zip instead of downloading it; SHA256SUMS must be beside it,
    and SHA256SUMS.sig too when there is a key.
.PARAMETER Key
    The release key to check SHA256SUMS.sig with; an upgrade uses the installed one without it.
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
.PARAMETER UpdateBy
    System mode: let this account or group run vigil self update without
    admin rights, to the latest release, or to the release the
    configuration names.
.PARAMETER Upgrade
    Only replace an installed Vigil, as vigil self update does: no vigil
    init, no PATH change, and the service is left as it was found.
.PARAMETER Reload
    With -Upgrade: a supervisor runs this root without a service (the
    vigil_update worker says so). Wait for it to reload, as for a service.
#>

param(
    [switch]$User,
    [switch]$System,
    [string]$Prefix,
    [string]$Version,
    [string]$Archive,
    [string]$Key,
    [ValidateSet('powershell', 'pwsh')][string]$ShellHost = 'powershell',
    [string]$Instance,
    [string]$Backend,
    [switch]$NoInit,
    [switch]$NoService,
    [string]$UpdateBy,
    [switch]$Upgrade,
    [switch]$Reload
)
# Read now: PowerShell names ignore case, so $reload below is this same variable.
$reloadAsked = $Reload.IsPresent
$needActive = $true

# Restored at the end, for the same reason.
$savedPreferences = @($ErrorActionPreference, $ProgressPreference)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$repoUrl = 'https://github.com/godspeedhq/vigil'

# Never exit: under irm | iex this runs in the caller's own session, which
# exit would close. A failure throws instead.
# Every failure comes through here, and the finally at the end of this file
# cleans up after all of them.
function Stop-Install {
    param([string]$Message)
    throw "install: $Message"
}

# Whether SHA256SUMS.sig is a signature over SHA256SUMS from the public key in
# a PEM file, as Test-VigilSignature in SelfUpdate.ps1, which this cannot load:
# it runs before Vigil is installed. Read by hand because Windows PowerShell
# 5.1's .NET cannot import PEM. Anything unexpected is "not signed".
function Test-InstallSignature {
    param([string]$KeyFile, [string]$Data, [string]$Signature)
    try {
        $s = @{ B = [Convert]::FromBase64String(([System.IO.File]::ReadAllText($KeyFile) -replace '-----[^-]+-----', '' -replace '\s', '')); P = 0 }
        # One DER element at $s.P: its start and length, with $s.P moved past
        # its header.
        $read = {
            $len = [int]$s.B[$s.P + 1]
            $s.P += 2
            if ($len -band 0x80) {
                $n = $len -band 0x7F
                $len = 0
                for ($i = 0; $i -lt $n; $i++) { $len = $len * 256 + $s.B[$s.P]; $s.P++ }
            }
            if ($s.P + $len -gt $s.B.Length) { throw 'truncated' }
            return @{ Start = $s.P; Len = $len }
        }
        # SubjectPublicKeyInfo holds an algorithm, then a BIT STRING holding
        # the RSA modulus and exponent; $s.P++ skips its unused-bits byte.
        [void](& $read)
        $alg = & $read
        $s.P = $alg.Start + $alg.Len
        [void](& $read)
        $s.P++
        [void](& $read)
        $n = & $read
        $s.P = $n.Start + $n.Len
        $e = & $read
        $from = $n.Start
        $len = $n.Len
        # DER adds a leading zero when the top bit is set; RSAParameters must not have it.
        if ($s.B[$from] -eq 0) { $from++; $len-- }
        $p = New-Object System.Security.Cryptography.RSAParameters
        $p.Modulus = [byte[]]$s.B[$from..($from + $len - 1)]
        $p.Exponent = [byte[]]$s.B[$e.Start..($e.Start + $e.Len - 1)]
        $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
        $rsa.ImportParameters($p)
        return $rsa.VerifyData([System.IO.File]::ReadAllBytes($Data), 'SHA256', [System.IO.File]::ReadAllBytes($Signature))
    }
    catch { return $false }
}

# PowerShell 5.1 on older servers may not offer TLS 1.2 by default.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Tests only (22.4.4): releases from a local server, never over the network.
if ($env:VIGIL_TEST_RELEASE_URL) {
    if ($env:VIGIL_TEST_RELEASE_URL -cnotmatch '^http://127\.0\.0\.1:[0-9]+$') { Stop-Install 'VIGIL_TEST_RELEASE_URL must be http://127.0.0.1:<port>' }
    $repoUrl = $env:VIGIL_TEST_RELEASE_URL
}

$admin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if ($User -and $System) { Stop-Install 'choose -User or -System, not both' }
$mode = if ($System) { 'system' } elseif ($User) { 'user' } elseif ($admin) { 'system' } else { 'user' }
if ($mode -ceq 'system' -and -not $admin) { Stop-Install 'system mode needs an elevated prompt; or use -User' }
$root = if ($Prefix) { $Prefix } elseif ($mode -ceq 'system') { Join-Path $env:ProgramData 'Vigil' } else { Join-Path $env:LOCALAPPDATA 'Vigil' }
# Made absolute: it ends up in the service definition and on the PATH, which do
# not run from this folder.
$root = [System.IO.Path]::GetFullPath($root)
# The key that SHA256SUMS.sig must verify against (17): the one given, else the
# one of the Vigil being upgraded, as vigil self update uses. A fresh install
# without -Key has none, and relies on GitHub and HTTPS as before. With a key
# the signature is required: one that is only checked when it is there is no
# check, as whoever can replace the archive can remove it.
$installedKey = Join-Path $root 'app\release-key.pem'
if ($Key) {
    if (-not (Test-Path -LiteralPath $Key -PathType Leaf)) { Stop-Install "no release key at $Key" }
    $Key = (Resolve-Path -LiteralPath $Key).ProviderPath
}
elseif ($env:VIGIL_TEST_RELEASE_URL -and $env:VIGIL_TEST_RELEASE_KEY) { $Key = $env:VIGIL_TEST_RELEASE_KEY }
elseif (Test-Path -LiteralPath $installedKey -PathType Leaf) { $Key = $installedKey }
if ($UpdateBy) {
    if ($mode -cne 'system' -or $Upgrade) { Stop-Install '-UpdateBy is for a system install: a user install updates itself' }
    # Checked now, so a mistyped name fails before anything is installed rather
    # than at the last step.
    try { [void](New-Object Security.Principal.NTAccount($UpdateBy)).Translate([Security.Principal.SecurityIdentifier]) }
    catch { Stop-Install "no account or group is called $UpdateBy" }
}

# --- 1. Prerequisites (5.1), before anything changes ------------------------

if ($PSVersionTable.PSVersion -lt [Version]'5.1') { Stop-Install "Windows PowerShell 5.1 or later is required (this is $($PSVersionTable.PSVersion))" }
if (-not $NoService -and $ShellHost -ceq 'pwsh' -and -not (Get-Command -Name 'pwsh.exe' -CommandType Application -ErrorAction SilentlyContinue)) {
    Stop-Install 'PowerShell 7 (pwsh) is not installed; install it, or use -ShellHost powershell'
}

# --- 2. The archive, verified ---------------------------------------------------

# Removed by the finally at the end, on every way out.
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
        if ($Key) {
            if (-not (Test-Path -LiteralPath "$sums.sig")) { Stop-Install "no SHA256SUMS.sig beside $Archive`: the archive cannot be verified against $Key; nothing was changed" }
            Copy-Item -LiteralPath "$sums.sig" -Destination (Join-Path $work 'SHA256SUMS.sig')
        }
    }
    else {
        if (-not $Version) {
            # The latest release, from where GitHub redirects /releases/latest
            # (the API allows only 60 requests an hour per address, too few
            # for a fleet behind one), or from the API when that page fails
            # (it has answered 504 while the downloads worked). Tests serve
            # the API's answer at <repo url>/api/releases/latest.
            $why = ''
            try {
                $r = Invoke-WebRequest -UseBasicParsing -Method Head -Uri "$repoUrl/releases/latest"
                $tag = if ($r.BaseResponse.ResponseUri) { [string]$r.BaseResponse.ResponseUri.AbsoluteUri } else { [string]$r.BaseResponse.RequestMessage.RequestUri.AbsoluteUri }
                if ($tag -cmatch '/v([^/]+)$') { $Version = $Matches[1] }
            }
            catch { $why = $_.Exception.Message }
            if (-not $Version) {
                $api = if ($repoUrl -clike 'https://github.com/*') { "https://api.github.com/repos/$($repoUrl.Substring(19))/releases/latest" } else { "$repoUrl/api/releases/latest" }
                try {
                    $tag = [string](Invoke-RestMethod -UseBasicParsing -Headers @{ Accept = 'application/vnd.github+json' } -Uri $api).tag_name
                    if ($tag -cmatch '^v([^/]+)$') { $Version = $Matches[1] }
                }
                catch { if (-not $why) { $why = $_.Exception.Message } }
            }
            if (-not $Version) { Stop-Install "cannot reach GitHub to find the latest release$(if ($why) { ": $why" })" }
        }
        $Version = $Version.TrimStart('v')
        $file = "vigil-$Version.zip"
        Write-Output "downloading Vigil $Version"
        try {
            Invoke-WebRequest -UseBasicParsing -Uri "$repoUrl/releases/download/v$Version/$file" -OutFile (Join-Path $work $file)
            Invoke-WebRequest -UseBasicParsing -Uri "$repoUrl/releases/download/v$Version/SHA256SUMS" -OutFile (Join-Path $work 'SHA256SUMS')
        }
        catch { Stop-Install "cannot download Vigil $Version`: $($_.Exception.Message)" }
        if ($Key) {
            try { Invoke-WebRequest -UseBasicParsing -Uri "$repoUrl/releases/download/v$Version/SHA256SUMS.sig" -OutFile (Join-Path $work 'SHA256SUMS.sig') }
            catch { Stop-Install "cannot download SHA256SUMS.sig: Vigil $Version cannot be verified against $Key; nothing was changed" }
        }
    }
    # The signature first: SHA256SUMS is only worth checking the archive
    # against once it is known to be the release's own.
    if ($Key) {
        if (-not (Test-InstallSignature -KeyFile $Key -Data (Join-Path $work 'SHA256SUMS') -Signature (Join-Path $work 'SHA256SUMS.sig'))) {
            Stop-Install "SHA256SUMS is not signed by the release key $Key; nothing was changed"
        }
        Write-Output "verified SHA256SUMS (signed by $Key)"
    }
    # The check that everything rests on. Nothing has been unpacked yet, and a
    # missing entry fails just as a wrong hash does: "no entry" must never read as
    # "nothing to check". sha256sum marks binary files with a leading *.
    $want = ''
    foreach ($l in [System.IO.File]::ReadAllLines((Join-Path $work 'SHA256SUMS'))) {
        $f = $l -split '\s+', 2
        if ($f.Count -eq 2 -and $f[1].TrimStart('*') -ceq $file) { $want = $f[0].ToLowerInvariant() }
    }
    if (-not $want) { Stop-Install "SHA256SUMS has no entry for $file" }
    $got = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $work $file)).Hash.ToLowerInvariant()
    if ($got -cne $want) { Stop-Install "SHA-256 mismatch for $file`: expected $want, got $got; nothing was changed" }
    Write-Output "verified $file (SHA-256 $got)"
    # Only the downloads above use it: pre-flight refuses it (22.4.4).
    Remove-Item Env:\VIGIL_TEST_RELEASE_URL -ErrorAction SilentlyContinue

    $x = Join-Path $work 'x'
    Expand-Archive -LiteralPath (Join-Path $work $file) -DestinationPath $x
    $src = @(Get-ChildItem -LiteralPath $x -Directory)[0].FullName
    if (-not (Test-Path -LiteralPath (Join-Path $src 'app\vigil.ps1'))) { Stop-Install "$file does not hold a Vigil release" }
    # Verified: the downloaded-from-the-internet mark would make a
    # RemoteSigned policy refuse Vigil's scripts.
    Get-ChildItem -LiteralPath $src -Recurse -File | Unblock-File
    # The archive's own VERSION wins over what was asked for: with -Archive nothing
    # else says which version this is, and the upgrade below compares against it.
    $verFile = Join-Path $src 'app\VERSION'
    if (Test-Path -LiteralPath $verFile) { $Version = ([System.IO.File]::ReadAllText($verFile)).Trim() }

    # --- 3. Unpack into the root ----------------------------------------------------

    $vigil = Join-Path $root 'app\vigil.ps1'
    $present = Test-Path -LiteralPath $vigil
    if ($Upgrade -and -not $present) { Stop-Install "no Vigil in $root to upgrade" }
    [void](New-Item -ItemType Directory -Force -Path $root)
    # Copied before anything is stopped: a full disk changes nothing.
    # vendor\ holds NSSM, which only Windows needs, so it is replaced with app\.
    $parts = @('app', 'vendor')
    foreach ($d in $parts) {
        Get-ChildItem -LiteralPath $root -Directory -Filter "$d.old.*" -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        foreach ($p in @("$d.new", "$d.old")) {
            $q = Join-Path $root $p
            if (-not (Test-Path -LiteralPath $q)) { continue }
            Remove-Item -LiteralPath $q -Recurse -Force -ErrorAction SilentlyContinue
            # The service's NSSM runs on from the vendor\ an earlier upgrade
            # renamed to vendor.old, until the service restarts: a running
            # program cannot be deleted, but it can be moved aside, and goes
            # at a later upgrade.
            if (Test-Path -LiteralPath $q) { Rename-Item -LiteralPath $q -NewName "$p.$((Get-Date).ToString('yyyyMMddHHmmss'))" }
        }
        try { Copy-Item -LiteralPath (Join-Path $src $d) -Destination (Join-Path $root "$d.new") -Recurse }
        catch {
            foreach ($p in $parts) { Remove-Item -LiteralPath (Join-Path $root "$p.new") -Recurse -Force -ErrorAction SilentlyContinue }
            Stop-Install "cannot copy into $root; nothing was changed: $($_.Exception.Message)"
        }
    }
    $running = $false
    $reload = $false
    # The same shell that is running this: Windows PowerShell or PowerShell 7.
    $self = (Get-Process -Id $PID).Path
    # A process of its own each time, so a new version's functions can never mix
    # with what this session has loaded, and an exit in it cannot end this script.
    function Invoke-Vigil { & $self -NoProfile -ExecutionPolicy Bypass -File $vigil -Root $root @args }
    # Whether the running service is on a version within 30 seconds.
    # Both must be true: the version is only what the supervisor last wrote down,
    # so the service has to be active as well. It gets 30 seconds because a
    # supervisor notices a change to app/ at its next tick, not at once.
    function Test-OnVersion {
        param([string]$Want)
        for ($n = 0; $n -lt 30; $n++) {
            if ("$(Invoke-Vigil version --supervisor 2>$null)" -ceq $Want -and
                (-not $needActive -or "$(Invoke-Vigil status 2>$null | Select-Object -First 1)".StartsWith('service: active'))) { return $true }
            Start-Sleep -Seconds 1
        }
        return $false
    }
    # What was found running decides how the service is treated, and Undo-Upgrade
    # puts back exactly that, so an upgrade never starts a service that was stopped.
    $oldVersion = ''
    if ($present -and (Test-Path -LiteralPath (Join-Path $root 'app\VERSION'))) { $oldVersion = ([System.IO.File]::ReadAllText((Join-Path $root 'app\VERSION'))).Trim() }
    if ($present -and -not $NoService) {
        $st = Invoke-Vigil status 2>$null | Select-Object -First 1
        if ("$st".StartsWith('service: active')) {
            $running = $true
            # A supervisor that can hot reload replaces itself when app\
            # changes (18.7): the service is not touched. An older one is
            # stopped and started.
            if ("$(Invoke-Vigil version --supervisor 2>$null)") { $reload = $true }
            else {
                Invoke-Vigil stop | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    foreach ($p in $parts) { Remove-Item -LiteralPath (Join-Path $root "$p.new") -Recurse -Force -ErrorAction SilentlyContinue }
                    Stop-Install 'cannot stop the running service for the upgrade; nothing was changed'
                }
            }
        }
    }
    # A supervisor running without a service (18.11): it reloads itself all
    # the same, and is waited for the same way, without a service to be
    # active. There is no service to start again if it goes wrong.
    if ($present -and $reloadAsked -and -not $reload) {
        $reload = $true
        $needActive = $false
    }

    # Windows refuses to rename a folder while a process has a file in it
    # open, and every Vigil process reads app\ as it starts, so on a busy host
    # the refusal lasts a moment.
    function Rename-Waiting {
        param([string]$Path, [string]$Name)
        for ($i = 0; ; $i++) {
            try {
                Rename-Item -LiteralPath $Path -NewName $Name -ErrorAction Stop
                return
            }
            catch {
                if ($i -ge 120) { throw }
                if ($i -eq 0) { Write-Output "waiting for processes reading $Path" }
                Start-Sleep -Milliseconds 250
            }
        }
    }

    # The same refusal holds a delete back: retried as long as a rename is.
    function Remove-Waiting {
        param([string]$Path)
        for ($i = 0; ; $i++) {
            try {
                Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
                return
            }
            catch {
                if ($i -ge 120) { throw }
                if ($i -eq 0) { Write-Output "waiting for processes reading $Path" }
                Start-Sleep -Milliseconds 250
            }
        }
    }

    # Back to what was installed: whatever was swapped, and the service.
    # Works from whatever is there, not from how far the swap got: it can be called
    # with app\ swapped and vendor\ not. The reason goes last, in Stop-Install, so
    # it is what whoever is running this reads. A supervisor that reloaded to the
    # new version reloads back by itself; if it does not, it is started.
    function Undo-Upgrade {
        param([string]$Why)
        foreach ($d in $parts) {
            $old = Join-Path $root "$d.old"
            if (Test-Path -LiteralPath $old) {
                $to = Join-Path $root $d
                if (Test-Path -LiteralPath $to) { Remove-Waiting -Path $to }
                Rename-Waiting -Path $old -Name $d
            }
            Remove-Item -LiteralPath (Join-Path $root "$d.new") -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($reload) { if (-not (Test-OnVersion $oldVersion) -and $needActive) { Invoke-Vigil start | Out-Null } }
        elseif ($running) { Invoke-Vigil start | Out-Null }
        Stop-Install "$Why; went back to the version that was installed"
    }

    # app\ and vendor\ are swapped whole, so a process still running the old
    # ones keeps reading files that stay intact.
    try {
        # The access -UpdateBy gave to app\ stays with it.
        if (Test-Path -LiteralPath (Join-Path $root 'update')) { Set-Acl -LiteralPath (Join-Path $root 'app.new') -AclObject (Get-Acl -LiteralPath (Join-Path $root 'app')) }
        foreach ($d in $parts) {
            if (Test-Path -LiteralPath (Join-Path $root $d)) { Rename-Waiting -Path (Join-Path $root $d) -Name "$d.old" }
            Rename-Waiting -Path (Join-Path $root "$d.new") -Name $d
        }
    }
    catch { Undo-Upgrade "cannot replace $root\app: $($_.Exception.Message)" }
    # The old version goes only once the new one has proved it runs.
    # Three proofs in increasing order of cost: the new code runs at all, then the
    # supervisor is really on it, then it stays up.
    if ($present) {
        if ("$(Invoke-Vigil version 2>$null)" -cne "Vigil $Version") { Undo-Upgrade "the new version ($Version) does not run" }
        if ($reload) {
            if (-not (Test-OnVersion $Version)) { Undo-Upgrade "the supervisor did not come up as $Version" }
        }
        elseif ($running) {
            Invoke-Vigil start | Out-Null
            if ($LASTEXITCODE -ne 0) { Undo-Upgrade "the new version ($Version) did not start" }
            if (-not (Test-OnVersion $Version)) { Undo-Upgrade "the new version ($Version) did not stay up" }
        }
        foreach ($d in $parts) { Remove-Item -LiteralPath (Join-Path $root "$d.old") -Recurse -Force -ErrorAction SilentlyContinue }
        Write-Output "upgraded $root to Vigil $Version"
    }
    else { Write-Output "installed Vigil $Version in $root" }
    # vigil self update stops here: an update replaces Vigil and nothing else, so it
    # can never touch packs, the PATH, the configuration or the service.
    if ($Upgrade) {
        Write-Output "done: Vigil $Version"
        return
    }

    # The packs, on a fresh install: vigil pack update replaces them later,
    # and an upgrade leaves them alone (18.10).
    $srcPacks = Join-Path $src 'packs'
    if (Test-Path -LiteralPath $srcPacks) {
        foreach ($p in Get-ChildItem -LiteralPath $srcPacks -Directory) {
            $to = Join-Path $root "packs\$($p.Name)"
            # A pack that is already here stays as it is: reinstalling must not undo a
            # vigil pack update.
            if (Test-Path -LiteralPath $to) { continue }
            [void](New-Item -ItemType Directory -Force -Path $to)
            Copy-Item -LiteralPath (Join-Path $p.FullName 'pack.config') -Destination $to
            $own = Join-Path $p.FullName 'windows'
            if (Test-Path -LiteralPath $own) { Get-ChildItem -LiteralPath $own -File | Copy-Item -Destination $to }
        }
    }

    # --- 4. The vigil command: app\bin on the PATH -----------------------------------

    # app\bin holds only vigil.cmd: with app\ itself on the PATH, PowerShell would
    # run vigil.ps1, which an execution policy that refuses scripts stops.
    $app = Join-Path $root 'app'
    $bin = Join-Path $app 'bin'
    $scope = if ($mode -ceq 'system') { 'Machine' } else { 'User' }
    $path = [Environment]::GetEnvironmentVariable('Path', $scope)
    # Read from the registry scope, not $env:Path, which also holds the other
    # scope's entries and would copy them across. Added only once, so reinstalling
    # does not grow the PATH; app\, where earlier versions put it, gives way.
    $entries = @("$path".Split(';') | Where-Object { $_ -and $_.TrimEnd('\') -ine $app })
    $had = $entries.Count -ne @("$path".Split(';') | Where-Object { $_ }).Count
    if ($had -or -not (@($entries | Where-Object { $_.TrimEnd('\') -ieq $bin }).Count)) {
        if (-not (@($entries | Where-Object { $_.TrimEnd('\') -ieq $bin }).Count)) { $entries += $bin }
        [Environment]::SetEnvironmentVariable('Path', ($entries -join ';'), $scope)
        Write-Output "added $bin to the $($scope.ToLowerInvariant()) PATH$(if ($had) { " in place of $app" }): close every terminal window (all of Windows Terminal), then a new one runs vigil"
    }

    # --- 5. vigil init, on a fresh install ----------------------------------------------

    # An existing configuration is never rewritten, whatever else was asked for.
    if (-not $NoInit -and -not $Upgrade -and -not (Test-Path -LiteralPath (Join-Path $root 'config\vigil.config'))) {
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
        if (-not $present -or "$st".StartsWith('service: not registered')) {
            Invoke-Vigil service install "--$mode" --host $ShellHost
            if ($LASTEXITCODE -ne 0) {
                Write-Output ''
                Write-Output 'Vigil is installed but not running: the reason is above (a failed check,'
                Write-Output "or the supervisor would not start). Once it is dealt with, run: vigil service install --$mode --host $ShellHost"
                Stop-Install 'the service was not registered'
            }
        }
    }

    # --- 7. Who may update it -----------------------------------------------------------

    if ($UpdateBy) {
        # Last: it locks the root down, so the steps above have to be finished first.
        Invoke-Vigil self update-by $UpdateBy
        if ($LASTEXITCODE -ne 0) { Stop-Install "$UpdateBy was not given the update" }
    }
    Write-Output ''
    Write-Output "done: Vigil $Version. vigil status shows what it is doing."
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    $ErrorActionPreference, $ProgressPreference = $savedPreferences
}
