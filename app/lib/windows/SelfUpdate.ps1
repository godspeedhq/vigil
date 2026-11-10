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
    Get-VigilReleaseSource -Root <dir>
        Where releases come from: @{ Base; Mirror; Path; From; Error; Retry;
        Header }, from [vigil] release_url or release_path when one is set,
        else GitHub (18.7). Path is true for a release_path: a folder, copied
        from. Header is the release_url's, its secret resolved; Retry, that
        the Error may pass (a secret that could not be had).
    Get-VigilLatestVersion -Base <url or folder> -Mirror <bool> -Path <bool> -TimeoutSec <n>
        The latest release's version, or $null.
    Get-VigilReleaseFile -Src <release source> -Rel <path in the release tree> -OutFile <file>
        Downloads, or for a release_path copies, one file of the releases.
        Throws when it is not there.
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
    $releases = (Get-VigilConfigSetting -Root $Root -Key 'release_url') + (Get-VigilConfigSetting -Root $Root -Key 'release_path')
    if ($releases) { '{0,-11} {1}' -f 'Releases', $releases }
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
            $argv = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $App 'vigil.ps1'), '-Root', $Root, 'self', 'refresh-check')
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

# Where releases come from (18.7): [vigil] release_url or release_path when
# the configuration sets one, else GitHub, or in tests the local server that
# stands for GitHub.
# Redirecting updates gains nothing: whatever is downloaded must be signed by
# the release key installed here, and a release that is not newer is never
# taken as the latest. A release_url is https, or plain http to this machine
# only, as for a log destination: checked here too, since the configuration
# is read here without being validated.
function Get-VigilReleaseSource {
    param([string]$Root)
    $src = @{ Base = 'https://github.com/godspeedhq/vigil'; Mirror = $false; Path = $false; From = 'GitHub'; Error = ''; Retry = $false; Header = $null }
    # Tests only (22.4.4): releases from a local server, never over the
    # network. It stands for GitHub, so a release_url still wins.
    if ($env:VIGIL_TEST_RELEASE_URL) {
        if ($env:VIGIL_TEST_RELEASE_URL -cnotmatch '^http://127\.0\.0\.1:[0-9]+$') { $src.Error = 'VIGIL_TEST_RELEASE_URL must be http://127.0.0.1:<port>'; return $src }
        $src.Base = $env:VIGIL_TEST_RELEASE_URL
    }
    $parsed = Get-VigilConfigParsed -Root $Root
    $setting = { param($Key) if ($null -eq $parsed) { return '' }; return [string](Get-VigilConfigValue $parsed 'vigil' $Key '') }
    $url = & $setting 'release_url'
    $folder = & $setting 'release_path'
    $hname = & $setting 'release_header_name'
    $hvalue = & $setting 'release_header_value'
    if ($url -and $folder) { $src.Error = "[vigil] sets both 'release_url' and 'release_path': use one"; return $src }
    # A login for a release_url: a header, as for a source (6.9), whose value
    # is a secret reference resolved below. Only ever sent to a release_url.
    if ($hname -or $hvalue) {
        if (-not ($hname -and $hvalue)) { $src.Error = "[vigil] needs both 'release_header_name' and 'release_header_value'"; return $src }
        if (-not $url) { $src.Error = "[vigil] sets 'release_header_name' without 'release_url': the header is sent only to a release_url"; return $src }
        if ($hname -cnotmatch '^[A-Za-z0-9-]+$') { $src.Error = "'release_header_name' must be a header name (letters, digits and -): $hname"; return $src }
    }
    # A folder: copied from, not downloaded. A UNC path or one on a drive:
    # a service has no mapped drive letters, and a path from the root of the
    # current drive would depend on where Vigil was started.
    if ($folder) {
        if ($folder -cnotmatch '^(\\\\[^\\]|[A-Za-z]:[\\/])') { $src.Error = "'release_path' must be an absolute path here (\\server\share\... or C:\...): $folder"; return $src }
        $src.Base = $folder.TrimEnd('\', '/')
        if ($src.Base -cmatch '^[A-Za-z]:$') { $src.Base += '\' }
        $src.Mirror = $true
        $src.Path = $true
        $src.From = $src.Base
        return $src
    }
    if (-not $url) { return $src }
    if (-not ($url.StartsWith('https://', [System.StringComparison]::Ordinal) -or $url -cmatch '^http://(localhost|127\.0\.0\.1|\[::1\])([:/]|$)')) {
        $src.Error = "'release_url' must start with https://"
        return $src
    }
    $src.Base = $url.TrimEnd('/')
    $src.Mirror = $true
    $src.From = $src.Base
    if (-not $hname) { return $src }
    # Resolved once, held in memory for this command only. A secret that
    # cannot be had now may be there later: worth trying again (18.11).
    $sec = Resolve-VigilSecret -Root $Root -Parsed $parsed -Reference $hvalue
    if (-not $sec.Ok) { $src.Error = "release_header_value $hvalue unavailable: $($sec.Why)"; $src.Retry = $true; return $src }
    if ([string]$sec.Value -cmatch '[\x00-\x1f\x7f]') { $src.Error = "release_header_value $hvalue holds a control character"; return $src }
    $src.Header = @{ $hname = [string]$sec.Value }
    return $src
}

# One request to a release_url, with its header when there is one, into
# $OutFile, or returning the content. No redirect is followed while there is a
# header: it would be sent on to whatever host a redirect names. A refusal
# leaves its status in $Script:VigilReleaseStatus; throws on any failure.
$Script:VigilReleaseStatus = 0
function Invoke-VigilReleaseGet {
    param([string]$Uri, [hashtable]$Header, [int]$TimeoutSec, [string]$OutFile = '')
    $Script:VigilReleaseStatus = 0
    # With a header, as a source's (Fetch.ps1): the redirect is answered, not
    # followed, and its status is known on every PowerShell.
    if ($Header) {
        $req = [System.Net.HttpWebRequest]::Create($Uri)
        $req.Method = 'GET'
        $req.Timeout = $TimeoutSec * 1000
        $req.ReadWriteTimeout = $TimeoutSec * 1000
        $req.AllowAutoRedirect = $false
        if ($Uri -cmatch '^http://(localhost|127\.0\.0\.1|\[::1\])([:/]|$)') { $req.Proxy = $null }
        foreach ($k in $Header.Keys) { $req.Headers.Add($k, $Header[$k]) }
        $resp = $null
        try { $resp = $req.GetResponse() }
        catch {
            $e = $_.Exception
            while ($e -and -not ($e -is [System.Net.WebException])) { $e = $e.InnerException }
            if ($e -and $e.Response) { $resp = $e.Response } else { throw }
        }
        try {
            $code = [int]$resp.StatusCode
            if ($code -ne 200) { $Script:VigilReleaseStatus = $code; throw "HTTP $code" }
            $in = $resp.GetResponseStream()
            $ms = New-Object System.IO.MemoryStream
            $in.CopyTo($ms)
            if ($OutFile) { [System.IO.File]::WriteAllBytes($OutFile, $ms.ToArray()); return }
            return [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
        }
        finally { $resp.Close() }
    }
    $a = @{ UseBasicParsing = $true; TimeoutSec = $TimeoutSec; Uri = $Uri; ErrorAction = 'Stop' }
    if ($OutFile) { $a.OutFile = $OutFile; $a.PassThru = $true }
    try { $r = Invoke-WebRequest @a }
    catch {
        $e = $_.Exception
        while ($e -and -not $e.Response) { $e = $e.InnerException }
        if ($e -and $e.Response) { $Script:VigilReleaseStatus = [int]$e.Response.StatusCode }
        throw
    }
    $code = [int]$r.StatusCode
    if ($code -ne 200) {
        $Script:VigilReleaseStatus = $code
        if ($OutFile) { Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue }
        throw "HTTP $code"
    }
    if (-not $OutFile) {
        if ($r.Content -is [byte[]]) { return [System.Text.Encoding]::UTF8.GetString($r.Content) }
        return [string]$r.Content
    }
}

# Why a release_url refused the last request, when the answer was about the
# login or a redirect; '' otherwise.
function Get-VigilReleaseRefused {
    param($Src)
    if (-not $Src.Mirror -or $Src.Path) { return '' }
    $code = $Script:VigilReleaseStatus
    if ($code -eq 401 -or $code -eq 403) {
        if ($Src.Header) { return "$($Src.From) refused the login (HTTP $code): check release_header_value" }
        return "$($Src.From) asks for a login (HTTP $code): set release_header_name and release_header_value"
    }
    if ($Src.Header -and $code -ge 300 -and $code -lt 400) {
        return "$($Src.From) redirected the request (HTTP $code): Vigil follows no redirect while release_header_name is set"
    }
    return ''
}

# The latest release's version, or $null. From a release_url or a
# release_path, the one line of <base>/releases/latest/VERSION. From GitHub,
# where it redirects /releases/latest, or the GitHub API when that page fails
# (it has answered 504 for half an hour while the downloads worked). The
# redirect comes first: the API allows an address 60 requests an hour, too
# few for a fleet behind one. Tests serve the API's answer at
# <base>/api/releases/latest.
function Get-VigilLatestVersion {
    param([string]$Base, [bool]$Mirror, [int]$TimeoutSec, [bool]$Path = $false, [hashtable]$Header = $null)
    if ($Mirror) {
        try {
            if ($Path) {
                $text = [System.IO.File]::ReadAllText([System.IO.Path]::Combine($Base, 'releases\latest\VERSION'))
            }
            else {
                $text = Invoke-VigilReleaseGet -Uri "$Base/releases/latest/VERSION" -Header $Header -TimeoutSec $TimeoutSec
            }
            $tag = @($text.Split("`n"))[0].Trim()
            if ($tag -cmatch '^v?([0-9A-Za-z.-]+)$') { return $Matches[1] }
        }
        catch { }
        return $null
    }
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Method Head -TimeoutSec $TimeoutSec -Uri "$Base/releases/latest"
        $tag = if ($r.BaseResponse.ResponseUri) { [string]$r.BaseResponse.ResponseUri.AbsoluteUri } else { [string]$r.BaseResponse.RequestMessage.RequestUri.AbsoluteUri }
        if ($tag -cmatch '/v([^/]+)$') { return $Matches[1] }
    }
    catch { }
    $api = if ($Base -clike 'https://github.com/*') { "https://api.github.com/repos/$($Base.Substring(19))/releases/latest" } else { "$Base/api/releases/latest" }
    try {
        $tag = [string](Invoke-RestMethod -UseBasicParsing -TimeoutSec $TimeoutSec -Headers @{ Accept = 'application/vnd.github+json' } -Uri $api).tag_name
        if ($tag -cmatch '^v([^/]+)$') { return $Matches[1] }
    }
    catch { }
    return $null
}

# One file of the releases, $Rel under the source's base, into $OutFile:
# copied from a release_path, downloaded otherwise. Throws when it is not
# there.
function Get-VigilReleaseFile {
    param($Src, [string]$Rel, [string]$OutFile)
    if ($Src.Path) {
        Copy-Item -LiteralPath ([System.IO.Path]::Combine($Src.Base, $Rel.Replace('/', '\'))) -Destination $OutFile -ErrorAction Stop
        return
    }
    Invoke-VigilReleaseGet -Uri "$($Src.Base)/$Rel" -Header $Src.Header -TimeoutSec 60 -OutFile $OutFile
}

# How a source whose latest release could not be found is named: for a
# release_path, with the account, since a share the service's account
# cannot read is the usual reason.
function Get-VigilReleaseUnreadable {
    param($Src)
    if ($Src.Path) { return "cannot read the latest release from $($Src.From) (as $([Environment]::UserDomainName)\$([Environment]::UserName)): is it there, and readable by this account?" }
    $why = Get-VigilReleaseRefused $Src
    if ($why) { return "cannot read the latest release: $why" }
    return "cannot reach $($Src.From) to find the latest release"
}

# That refresh, as a detached process. Written whether or not it worked: a
# host with no way out tries once a day, not on every command.
function Update-VigilUpdateCache {
    param([string]$Root, [string]$App)
    $src = Get-VigilReleaseSource -Root $Root
    $f = Get-VigilUpdateCachePath
    $latest = ''
    try { if ([System.IO.File]::Exists($f)) { $latest = @([System.IO.File]::ReadAllText($f).Trim().Split(' '))[1] } } catch { }
    # A source that cannot be used (a secret this account cannot read, say)
    # counts as no answer.
    try {
        if ($src.Error) { throw $src.Error }
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $v = Get-VigilLatestVersion -Base $src.Base -Mirror $src.Mirror -Path $src.Path -TimeoutSec 10 -Header $src.Header
        if ($v) { $latest = $v }
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
    $src = Get-VigilReleaseSource -Root $Root
    if ($src.Error) {
        if ($src.Retry) { $Script:VigilUpdateKind = 'download' }
        return & $die $src.Error
    }
    $base = $src.Base
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
            $Want = Get-VigilLatestVersion -Base $base -Mirror $src.Mirror -Path $src.Path -TimeoutSec 60 -Header $src.Header
            if (-not $Want) { $Script:VigilUpdateKind = 'download'; return & $die (Get-VigilReleaseUnreadable $src) }
            # The latest is never older than what runs here: a source that
            # names an older release cannot move this back. Going back is
            # asked for by number (--version, or the configuration's version).
            if (Test-VigilNewer $current $Want) {
                Write-Output "Vigil $current is installed, newer than the latest release from $($src.From) ($Want): nothing to do"
                return
            }
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

        # A new folder of its own, never one that is already there (as for
        # install.ps1's).
        $work = Join-Path ([System.IO.Path]::GetTempPath()) ('vigil-update.' + [guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $work)
        $script = Join-Path $work 'install.ps1'
        $sums = Join-Path $work 'SHA256SUMS'
        $file = "vigil-$Want.zip"
        try {
            foreach ($f in @('install.ps1', $file, 'SHA256SUMS')) {
                Get-VigilReleaseFile -Src $src -Rel "releases/download/v$Want/$f" -OutFile (Join-Path $work $f)
            }
        }
        catch {
            $Script:VigilUpdateKind = 'download'
            $why = Get-VigilReleaseRefused $src
            if ($why) { return & $die "cannot download Vigil ${Want}: $why" }
            return & $die "cannot download Vigil ${Want}: is there such a release?"
        }
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
            Get-VigilReleaseFile -Src $src -Rel "releases/download/v$Want/SHA256SUMS.sig" -OutFile $sig
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
    return Get-VigilConfigSetting -Root $Root -Key 'version'
}

# A [vigil] setting from the active configuration when it is fetched, else
# from the file; empty when unset.
function Get-VigilConfigSetting {
    param([string]$Root, [string]$Key)
    $parsed = Get-VigilConfigParsed -Root $Root
    if ($null -eq $parsed) { return '' }
    try { return [string](Get-VigilConfigValue $parsed 'vigil' $Key '') }
    catch { return '' }
}

# The active configuration when it is fetched, else the file, parsed; $null
# when there is none or this account may not read it (-UpdateBy's account,
# 18.7): Test-Path's "Access is denied" is caught, not printed.
function Get-VigilConfigParsed {
    param([string]$Root)
    $ErrorActionPreference = 'Stop'
    try {
        $parsed = ConvertFrom-VigilConfig -Path (Join-Path $Root 'config\vigil.config')
        if (Test-VigilFetchMode $parsed) {
            $d = Get-VigilConfigValue $parsed 'vigil' 'state_dir' 'state'
            if (-not [System.IO.Path]::IsPathRooted($d)) { $d = Join-Path $Root $d }
            $a = Read-VigilActive -Root $Root -State $d
            if ($a) { $parsed = ConvertFrom-VigilConfig -Path $a.Config }
        }
        return $parsed
    }
    catch { return $null }
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
    # Its temporary files under the root, as for the update task: as SYSTEM
    # the machine's temporary folder is C:\Windows\Temp, where any account can
    # create files, and what is verified must stay as it is until it runs.
    $tmp = Join-Path $Root 'update\supervisor'
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $Root 'update'))
    [void](New-Item -ItemType Directory -Path $tmp)
    $psi.EnvironmentVariables['TEMP'] = $tmp
    $psi.EnvironmentVariables['TMP'] = $tmp
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $p.WaitForExit()
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
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
