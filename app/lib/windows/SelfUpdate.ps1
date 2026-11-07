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
    Vigil self-update - Windows PowerShell 5.1 compatible.
.DESCRIPTION
    vigil version and vigil self update (SPECIFICATION.md 18.7). An update
    is the installer of the release being installed, run with -Upgrade:
    there is one path that replaces Vigil, and it verifies, swaps and goes
    back if the new version does not run. This only finds the release and
    starts it. The twin of selfupdate.sh.

    Get-VigilPackaged -App <app dir>
        @{ Manager; Upgrade; Root } when a package manager installed this
        program (app\PACKAGED), else $null.
    Get-VigilVersion -App <app dir>
        "Vigil <version>", or says this is a copy from the repository.
    Get-VigilAbout -Root <dir> -App <app dir>
        What this is, who made it and where it runs.
    Invoke-VigilSelfUpdate -Root <dir> -App <app dir> -Check <bool> -Want <version> [-FromConfig <bool>]
        Returns an exit code: 0, or 1 with the reason on stderr; nothing is
        changed then. $Script:VigilUpdateKind says what went wrong: refused
        (nothing to retry: rights, signature, a repository copy), download
        (the release could not be fetched: worth trying again) or install
        (the installer ran and went back). -FromConfig lets an install that
        is not writable go through the task of install -UpdateBy (18.11).
    Get-VigilConfigVersion -Root <dir>
        The release [vigil] version asks for: the active configuration's
        when it is fetched, else the file's. Empty when unset.
    Invoke-VigilUpdate -Ctx <worker context> -Root <dir> -App <app dir> -Log <file> -RunId <id>
        The body of the vigil_update worker (18.11): self update
        --from-config in a process of its own, the outcome recorded in
        state\update.state.
    Invoke-VigilSelfUpdateTask -Root <dir> -App <app dir>
        The same, as the scheduled task of install -UpdateBy.
#>

# app\PACKAGED is written by a package's build (18.6), never by Vigil: the
# package manager owns this program, so self update leaves it to that, and the
# root is elsewhere. Lines of key = value: manager, upgrade and root.
function Get-VigilPackaged {
    param([string]$App)
    $f = Join-Path $App 'PACKAGED'
    if (-not [System.IO.File]::Exists($f)) { return $null }
    $r = @{ Manager = ''; Upgrade = ''; Root = ''; Service = '' }
    foreach ($l in [System.IO.File]::ReadAllLines($f)) {
        if ($l -cmatch '^(manager|upgrade|root|service) *= *(.*)$') {
            $k = @{ manager = 'Manager'; upgrade = 'Upgrade'; root = 'Root'; service = 'Service' }[$Matches[1]]
            if (-not $r[$k]) { $r[$k] = $Matches[2].TrimEnd() }
        }
    }
    if (-not $r.Manager) { $r.Manager = 'a package manager' }
    if (-not $r.Upgrade) { $r.Upgrade = 'its package manager' }
    return [pscustomobject]$r
}

# How this install is updated: vigil self update, or the package manager's
# command.
function Get-VigilUpdateHow {
    param([string]$App)
    $p = Get-VigilPackaged -App $App
    if ($p) { return $p.Upgrade }
    return 'vigil self update'
}

function Get-VigilVersion {
    param([string]$App)
    $f = Join-Path $App 'VERSION'
    if (Test-Path -LiteralPath $f) { return "Vigil $([System.IO.File]::ReadAllText($f).Trim())" }
    return 'Vigil, from the repository (no release)'
}

function Get-VigilAbout {
    param([string]$Root, [string]$App)
    Get-VigilVersion -App $App
    'A job scheduler, supervisor and metrics forwarder for Windows, Linux and macOS,'
    'written only in the shells that ship with each one.'
    ''
    '{0,-11} {1}' -f 'Created by', 'Bankole Ogundero and the Vigil contributors'
    '{0,-11} {1}' -f 'Licence', 'Apache-2.0'
    '{0,-11} {1}' -f 'Source', 'https://github.com/godspeedhq/vigil'
    '{0,-11} {1}' -f 'Docs', 'https://godspeedhq.github.io/vigil/'
    '{0,-11} {1}' -f 'Installed', $Root
    $p = Get-VigilPackaged -App $App
    if ($p) { '{0,-11} {1}, by {2}' -f 'Program', (Split-Path -Parent $App), $p.Manager }
    '{0,-11} {1}' -f 'Platform', "Windows, PowerShell $($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor)"
}

# Whether a signature over some data is from the public key in a PEM file.
# Read by hand because Windows PowerShell 5.1's .NET cannot import PEM.
function Test-VigilSignature {
    param([string]$KeyFile, [byte[]]$Data, [byte[]]$Signature)
    try {
        $text = [System.IO.File]::ReadAllText($KeyFile) -replace '-----[^-]+-----', '' -replace '\s', ''
        # A public key file is nested DER: SubjectPublicKeyInfo holds an algorithm, then
        # a BIT STRING holding the RSA modulus and exponent. The reads below walk down
        # to those two numbers, and $s.P++ skips the BIT STRING's unused-bits byte.
        # Anything unexpected throws, and the catch makes that "not signed".
        $s = @{ B = [Convert]::FromBase64String($text); P = 0 }
        [void](Read-VigilDer $s)
        $alg = Read-VigilDer $s
        $s.P = $alg.Start + $alg.Len
        [void](Read-VigilDer $s)
        $s.P++
        [void](Read-VigilDer $s)
        $n = Read-VigilDer $s
        $s.P = $n.Start + $n.Len
        $e = Read-VigilDer $s
        $from = $n.Start
        $len = $n.Len
        # DER adds a leading zero when the top bit is set; RSAParameters must not have it.
        if ($s.B[$from] -eq 0) { $from++; $len-- }
        $p = New-Object System.Security.Cryptography.RSAParameters
        $p.Modulus = [byte[]]$s.B[$from..($from + $len - 1)]
        $p.Exponent = [byte[]]$s.B[$e.Start..($e.Start + $e.Len - 1)]
        $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
        $rsa.ImportParameters($p)
        return $rsa.VerifyData($Data, 'SHA256', $Signature)
    }
    catch { return $false }
}

# The version the running supervisor wrote when it started, which is not always
# what is on disk: after an upgrade the two differ until it has reloaded. The
# installer relies on this to know when a reload has happened.
function Get-VigilSupervisorVersion {
    param([string]$Root)
    try {
        $parsed = ConvertFrom-VigilConfig -Path (Join-Path $Root 'config\vigil.config')
        $d = Get-VigilConfigValue $parsed 'vigil' 'state_dir' 'state'
        if (-not [System.IO.Path]::IsPathRooted($d)) { $d = Join-Path $Root $d }
        $f = Join-Path $d 'supervisor.version'
        if ([System.IO.File]::Exists($f)) { return [System.IO.File]::ReadAllText($f).Trim() }
    }
    catch { }
    return ''
}

# Whether version $A is newer than $B, comparing the numbers of x.y.z.
function Test-VigilNewer {
    param([string]$A, [string]$B)
    $x = $A.Split('.-'.ToCharArray()); $y = $B.Split('.-'.ToCharArray())
    for ($i = 0; $i -lt 3; $i++) {
        $p = if ($i -lt $x.Count) { $x[$i] } else { '0' }
        $q = if ($i -lt $y.Count) { $y[$i] } else { '0' }
        if ($p -cnotmatch '^[0-9]+$' -or $q -cnotmatch '^[0-9]+$') { return $false }
        if ([long]$p -gt [long]$q) { return $true }
        if ([long]$p -lt [long]$q) { return $false }
    }
    return $false
}

# Per user and outside the install, because a read-only system install has to
# be able to show the notice too.
function Get-VigilUpdateCachePath { return Join-Path $env:LOCALAPPDATA 'vigil-update-check' }

# Says on stderr when a newer release is known, at a console only. Reads a
# per-user cache, and refreshes it in the background once a day, so it never
# slows a command and a host with no way out never notices.
function Show-VigilUpdateNotice {
    param([string]$Root, [string]$App)
    if ($env:VIGIL_NO_UPDATE_CHECK -or -not (Test-Path -LiteralPath (Join-Path $App 'VERSION'))) { return }
    if (-not $env:VIGIL_TEST_RELEASE_URL -and ($env:CI -or [Console]::IsOutputRedirected -or [Console]::IsErrorRedirected)) { return }
    $at = [long]0; $latest = ''
    $f = Get-VigilUpdateCachePath
    try {
        if ([System.IO.File]::Exists($f)) {
            $p = [System.IO.File]::ReadAllText($f).Trim().Split(' ')
            if ($p[0] -cmatch '^[0-9]+$') { $at = [long]$p[0] }
            if ($p.Count -gt 1) { $latest = $p[1] }
        }
    }
    catch { }
    $current = [System.IO.File]::ReadAllText((Join-Path $App 'VERSION')).Trim()
    if ($latest -and (Test-VigilNewer $latest $current)) {
        [Console]::Error.WriteLine("`nVigil $latest is available (this is $current). To update: $(Get-VigilUpdateHow -App $App)")
    }
    if ([DateTimeOffset]::Now.ToUnixTimeSeconds() - $at -ge 86400) {
        try {
            $argv = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $App 'vigil.ps1'), 'self', 'refresh-check')
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = (Get-Process -Id $PID).Path
            $psi.Arguments = ($argv | ForEach-Object { ConvertTo-VigilQuotedArg -Arg $_ -Always $false }) -join ' '
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            [void][System.Diagnostics.Process]::Start($psi)
        }
        catch { }
    }
}

# That refresh, as a detached process. Written whether or not it worked: a
# host with no way out tries once a day, not on every command.
function Update-VigilUpdateCache {
    param([string]$App)
    $base = 'https://github.com/godspeedhq/vigil'
    if ($env:VIGIL_TEST_RELEASE_URL) { $base = $env:VIGIL_TEST_RELEASE_URL }
    $f = Get-VigilUpdateCachePath
    $latest = ''
    try { if ([System.IO.File]::Exists($f)) { $latest = @([System.IO.File]::ReadAllText($f).Trim().Split(' '))[1] } } catch { }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $r = Invoke-WebRequest -UseBasicParsing -Method Head -TimeoutSec 10 -Uri "$base/releases/latest"
        $tag = if ($r.BaseResponse.ResponseUri) { [string]$r.BaseResponse.ResponseUri.AbsoluteUri } else { [string]$r.BaseResponse.RequestMessage.RequestUri.AbsoluteUri }
        if ($tag -cmatch '/v([^/]+)$') { $latest = $Matches[1] }
    }
    catch { }
    try { [System.IO.File]::WriteAllText($f, "$([DateTimeOffset]::Now.ToUnixTimeSeconds()) $latest`n") } catch { }
}

$Script:VigilUpdateTask = 'Vigil Update'

# The task of install -UpdateBy (18.7), if it is this root's and this account
# may read it; otherwise $null.
function Get-VigilUpdateTask {
    param([string]$Root)
    try {
        $s = New-Object -ComObject Schedule.Service
        $s.Connect()
        $t = $s.GetFolder('\').GetTask($Script:VigilUpdateTask)
        # The name alone is not enough: another Vigil on this machine could own a task
        # called this, and this root must not start an update of that one.
        $tail = (ConvertTo-VigilQuotedArg -Arg $Root -Always $false) + ' self update --task'
        if (([string]$t.Definition.Actions.Item(1).Arguments).EndsWith($tail, [System.StringComparison]::OrdinalIgnoreCase)) { return $t }
    }
    catch { }
    return $null
}

# Asks the task for the update and shows what it writes. Returns its exit code.
function Invoke-VigilUpdateByTask {
    param([string]$Root, $Task)
    $out = Join-Path $Root 'update\output'
    # The task runs as SYSTEM, so its output cannot come back any other way than
    # through this file. The first write is how we know it has started.
    $before = [System.IO.File]::GetLastWriteTimeUtc($out)
    [void]$Task.Run($null)
    $shown = 0
    $start = [DateTime]::UtcNow
    while ([System.IO.File]::GetLastWriteTimeUtc($out) -eq $before) {
        if (([DateTime]::UtcNow - $start).TotalSeconds -gt 60) {
            [Console]::Error.WriteLine('vigil: the update task did not start')
            return 1
        }
        Start-Sleep -Milliseconds 250
    }
    while (([DateTime]::UtcNow - $start).TotalMinutes -lt 15) {
        $text = ''
        try {
            # Share mode: the task still has this file open for writing.
            $fs = [System.IO.File]::Open($out, 'Open', 'Read', 'ReadWrite,Delete')
            try { $text = (New-Object System.IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
        }
        catch { }
        # Whole lines only: the last piece may still be being written.
        $lines = $text.Split("`n")
        for ($i = $shown; $i -lt $lines.Count - 1; $i++) {
            if ($lines[$i] -cmatch '^exit: ([0-9]+)$') { return [int]$Matches[1] }
            Write-Output $lines[$i]
        }
        # Max: a read that failed above leaves no lines, and must not make what has
        # already been shown appear again.
        $shown = [Math]::Max($shown, $lines.Count - 1)
        Start-Sleep -Milliseconds 250
    }
    [Console]::Error.WriteLine('vigil: the update task did not finish within 15 minutes')
    return 1
}

# What the task runs, as SYSTEM: self update in a process of its own, its
# output where the account that asked can read it.
function Invoke-VigilSelfUpdateTask {
    param([string]$Root, [string]$App)
    $dir = Join-Path $Root 'update'
    $out = Join-Path $dir 'output'
    # stderr from the child is piped below, and Stop would turn its first line into
    # a failure of this function.
    $ErrorActionPreference = 'Continue'
    [System.IO.File]::WriteAllText($out, '')
    # Not the machine's temporary folder, where any account can create files:
    # what is verified must stay as it is until it runs.
    $tmp = Join-Path $dir 'work'
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
    [void](New-Item -ItemType Directory -Path $tmp)
    $env:TEMP = $tmp
    $env:TMP = $tmp
    $shell = (Get-Process -Id $PID).Path
    # The release the configuration names, when it names one (18.11).
    $how = @()
    if (Get-VigilConfigVersion -Root $Root) { $how = @('--from-config') }
    & $shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $App 'vigil.ps1') -Root $Root self update @how 2>&1 |
        ForEach-Object { [System.IO.File]::AppendAllText($out, "$_`n") }
    $code = $LASTEXITCODE
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    [System.IO.File]::AppendAllText($out, "exit: $code`n")
    return $code
}

# The order matters: everything that can be refused is refused before anything
# is downloaded, and everything downloaded is verified before anything runs.
# This function never changes the install itself. $pinned remembers that a
# version was asked for, since $Want is filled in with the latest one below.
function Invoke-VigilSelfUpdate {
    param([string]$Root, [string]$App, [bool]$Check, [string]$Want, [bool]$FromConfig = $false)
    $die = { param($Why) [Console]::Error.WriteLine("vigil: $Why"); return 1 }
    $Script:VigilUpdateKind = 'refused'
    $pinned = [bool]$Want
    $base = 'https://github.com/godspeedhq/vigil'
    # Tests only (22.4.4): releases from a local server, never over the
    # network.
    if ($env:VIGIL_TEST_RELEASE_URL) {
        if ($env:VIGIL_TEST_RELEASE_URL -cnotmatch '^http://127\.0\.0\.1:[0-9]+$') { return & $die 'VIGIL_TEST_RELEASE_URL must be http://127.0.0.1:<port>' }
        $base = $env:VIGIL_TEST_RELEASE_URL
    }
    $verFile = Join-Path $App 'VERSION'
    if (-not (Test-Path -LiteralPath $verFile)) { return & $die 'this copy comes from the repository, not a release: update it with git' }
    $current = [System.IO.File]::ReadAllText($verFile).Trim()
    # A package manager's program is its to replace: refused before anything is
    # downloaded. --check still says what is available.
    $packaged = Get-VigilPackaged -App $App
    if (-not $Check -and $packaged) { return & $die "Vigil was installed by $($packaged.Manager): update it with $($packaged.Upgrade)" }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $saved = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    $work = $null
    try {
        if (-not $Want) {
            # The latest release, from where GitHub redirects /releases/latest.
            try {
                $r = Invoke-WebRequest -UseBasicParsing -Method Head -TimeoutSec 60 -Uri "$base/releases/latest"
                $tag = if ($r.BaseResponse.ResponseUri) { [string]$r.BaseResponse.ResponseUri.AbsoluteUri } else { [string]$r.BaseResponse.RequestMessage.RequestUri.AbsoluteUri }
            }
            catch { $Script:VigilUpdateKind = 'download'; return & $die 'cannot reach GitHub to find the latest release' }
            if ($tag -cnotmatch '/v([^/]+)$') { return & $die "cannot tell the latest release from $tag" }
            $Want = $Matches[1]
        }
        if ($Want -ceq $current) {
            Write-Output "Vigil $current is installed: nothing to do"
            return
        }
        if ($Check) {
            Write-Output "Vigil $current is installed; $Want is available: $(Get-VigilUpdateHow -App $App)"
            return
        }

        # A system install needs an elevated prompt: found out now, not
        # half way.
        $probe = Join-Path $Root ".vigil-update.$PID"
        try {
            [System.IO.File]::WriteAllText($probe, '')
            [System.IO.File]::Delete($probe)
        }
        catch {
            # The task of install -UpdateBy (18.7) goes to the latest release,
            # or to the one the configuration names (18.11): never to one given
            # on the command line.
            $task = if ($pinned -and -not $FromConfig) { $null } else { Get-VigilUpdateTask -Root $Root }
            if ($task) {
                $code = Invoke-VigilUpdateByTask -Root $Root -Task $task
                if ($code -eq 2) { $Script:VigilUpdateKind = 'download' }
                elseif ($code -eq 3) { $Script:VigilUpdateKind = 'install' }
                return $code
            }
            return & $die "$Root is not writable: run this from an elevated prompt for a system install"
        }

        $work = Join-Path ([System.IO.Path]::GetTempPath()) "vigil-update.$PID"
        [void](New-Item -ItemType Directory -Force -Path $work)
        $script = Join-Path $work 'install.ps1'
        $sums = Join-Path $work 'SHA256SUMS'
        $file = "vigil-$Want.zip"
        try {
            foreach ($f in @('install.ps1', $file, 'SHA256SUMS')) {
                Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -Uri "$base/releases/download/v$Want/$f" -OutFile (Join-Path $work $f)
            }
        }
        catch { $Script:VigilUpdateKind = 'download'; return & $die "cannot download Vigil ${Want}: is there such a release?" }
        # The signature (17): whatever else was replaced on the server, the
        # key that checks it is the one already installed here. The archive
        # is handed to the installer, so what is verified is what is installed.
        $key = Join-Path $App 'release-key.pem'
        if ($env:VIGIL_TEST_RELEASE_URL -and $env:VIGIL_TEST_RELEASE_KEY) { $key = $env:VIGIL_TEST_RELEASE_KEY }
        # No key means nothing to check with, and that is refused like a bad
        # signature: every release since 0.2.1 carries the key, so a missing
        # one means this install has been changed.
        if (-not (Test-Path -LiteralPath $key -PathType Leaf)) {
            return & $die "the release key $key is missing: Vigil $Want cannot be verified; nothing was changed"
        }
        $sig = Join-Path $work 'SHA256SUMS.sig'
        $signed = $false
        try {
            Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -Uri "$base/releases/download/v$Want/SHA256SUMS.sig" -OutFile $sig
            $signed = Test-VigilSignature -KeyFile $key -Data ([System.IO.File]::ReadAllBytes($sums)) -Signature ([System.IO.File]::ReadAllBytes($sig))
        }
        catch { $signed = $false }
        if (-not $signed) { return & $die "Vigil $Want is not signed by the Vigil release key; nothing was changed" }
        # SHA256SUMS is what the signature covers, so this is what ties the installer
        # to the signature. The installer checks the archive against the same file.
        $sum = ''
        foreach ($l in [System.IO.File]::ReadAllLines($sums)) {
            $f = $l -split '\s+', 2
            if ($f.Count -eq 2 -and $f[1].TrimStart('*') -ceq 'install.ps1') { $sum = $f[0].ToLowerInvariant() }
        }
        if (-not $sum -or (Get-FileHash -Algorithm SHA256 -LiteralPath $script).Hash.ToLowerInvariant() -cne $sum) {
            return & $die "the installer of $Want does not match its SHA256SUMS; nothing was changed"
        }
        Write-Output "updating Vigil $current to $Want"
        # A process of its own: the running one's files are about to move.
        $shell = (Get-Process -Id $PID).Path
        # Following the configuration, a supervisor is running whether or not
        # there is a service: the installer waits for it to reload (18.11).
        $reloadArg = @()
        if ($FromConfig) { $reloadArg = @('-Reload') }
        & $shell -NoProfile -ExecutionPolicy Bypass -File $script -Upgrade @reloadArg -Prefix $Root -Archive (Join-Path $work $file)
        if ($LASTEXITCODE -ne 0) {
            $Script:VigilUpdateKind = 'install'
            return 1
        }
    }
    finally {
        $ProgressPreference = $saved
        if ($work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Get-VigilConfigVersion {
    param([string]$Root)
    try {
        $parsed = ConvertFrom-VigilConfig -Path (Join-Path $Root 'config\vigil.config')
        if (Test-VigilFetchMode $parsed) {
            $d = Get-VigilConfigValue $parsed 'vigil' 'state_dir' 'state'
            if (-not [System.IO.Path]::IsPathRooted($d)) { $d = Join-Path $Root $d }
            $a = Read-VigilActive -Root $Root -State $d
            if ($a) { $parsed = ConvertFrom-VigilConfig -Path $a.Config }
        }
        return [string](Get-VigilConfigValue $parsed 'vigil' 'version' '')
    }
    catch { return '' }
}

# How long a release that could not be downloaded waits before it is tried
# again (18.11). One that installed and failed is not tried again until the
# configuration names another.
$Script:VigilUpdateRetry = 300

function Invoke-VigilUpdate {
    param($Ctx, [string]$Root, [string]$App, [string]$Log, [string]$RunId)
    $want = [string](Get-VigilConfigValue $Ctx.Parsed 'vigil' 'version' '')
    if (-not $want) { return @{ Ok = $false; Reason = 'the configuration names no version' } }
    $verFile = Join-Path $App 'VERSION'
    $current = if ([System.IO.File]::Exists($verFile)) { [System.IO.File]::ReadAllText($verFile).Trim() } else { '' }
    # A process of its own, as for vigil self update: the installer replaces
    # app\ while it runs. It reads the version from the configuration itself.
    $argv = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $App 'vigil.ps1'),
        '-Root', $Root, 'self', 'update', '--from-config')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Process -Id $PID).Path
    $psi.Arguments = ($argv | ForEach-Object { ConvertTo-VigilQuotedArg -Arg $_ -Always $false }) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $p.WaitForExit()
    $text = $outTask.Result + $errTask.Result
    $code = $p.ExitCode
    $result = if ($code -eq 0) { 'succeeded' } elseif ($code -eq 2) { 'unavailable' } else { 'failed' }
    # Everything the update and its installer said, in the worker's log. The
    # reason is the last line that says why: the installer throws, so its
    # message comes back as an error record of several lines.
    $now = Get-VigilNow
    $reason = ''
    $last = ''
    $lines = New-Object System.Text.StringBuilder
    foreach ($l in $text.Split("`n")) {
        $l = $l.TrimEnd("`r")
        if (-not $l.Trim()) { continue }
        [void]$lines.Append("$($now.Iso) $RunId out $l`r`n")
        $last = $l.Trim()
        if ($l -cmatch '^(vigil|install): ') { $reason = $l -replace '^vigil: ', '' }
    }
    if (-not $reason) { $reason = $last }
    [System.IO.File]::AppendAllText($Log, $lines.ToString())
    Write-VigilFileAtomic -Path (Join-Path $Ctx.State 'update.state') -Text ("[update]`nversion = $want`nfrom    = $current`nresult  = $result`n" +
        "epoch   = $($now.Epoch)`nreason  = $reason`n")
    if ($result -ceq 'succeeded') { return @{ Ok = $true; Reason = '' } }
    return @{ Ok = $false; Reason = $reason }
}
