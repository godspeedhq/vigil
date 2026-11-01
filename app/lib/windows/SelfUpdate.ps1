#Requires -Version 5.1

<#
.SYNOPSIS
    Vigil self-update - Windows PowerShell 5.1 compatible.
.DESCRIPTION
    vigil version and vigil self update (SPECIFICATION.md 18.7). An update
    is the installer of the release being installed, run with -Upgrade:
    there is one path that replaces Vigil, and it verifies, swaps and goes
    back if the new version does not run. This only finds the release and
    starts it. The twin of selfupdate.sh.

    Get-VigilVersion -App <app dir>
        "Vigil <version>", or says this is a copy from the repository.
    Invoke-VigilSelfUpdate -Root <dir> -App <app dir> -Check <bool> -Want <version>
        Returns an exit code: 0, or 1 with the reason on stderr; nothing is
        changed then.
#>

function Get-VigilVersion {
    param([string]$App)
    $f = Join-Path $App 'VERSION'
    if (Test-Path -LiteralPath $f) { return "Vigil $([System.IO.File]::ReadAllText($f).Trim())" }
    return 'Vigil, from the repository (no release)'
}

function Invoke-VigilSelfUpdate {
    param([string]$Root, [string]$App, [bool]$Check, [string]$Want)
    $die = { param($Why) [Console]::Error.WriteLine("vigil: $Why"); return 1 }
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
            catch { return & $die 'cannot reach GitHub to find the latest release' }
            if ($tag -cnotmatch '/v([^/]+)$') { return & $die "cannot tell the latest release from $tag" }
            $Want = $Matches[1]
        }
        if ($Want -ceq $current) {
            Write-Output "Vigil $current is installed: nothing to do"
            return
        }
        if ($Check) {
            Write-Output "Vigil $current is installed; $Want is available: vigil self update"
            return
        }

        # A system install needs an elevated prompt: found out now, not
        # half way.
        $probe = Join-Path $Root ".vigil-update.$PID"
        try {
            [System.IO.File]::WriteAllText($probe, '')
            [System.IO.File]::Delete($probe)
        }
        catch { return & $die "$Root is not writable: run this from an elevated prompt for a system install" }

        $work = Join-Path ([System.IO.Path]::GetTempPath()) "vigil-update.$PID"
        [void](New-Item -ItemType Directory -Force -Path $work)
        $script = Join-Path $work 'install.ps1'
        $sums = Join-Path $work 'SHA256SUMS'
        try {
            Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -Uri "$base/releases/download/v$Want/install.ps1" -OutFile $script
            Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -Uri "$base/releases/download/v$Want/SHA256SUMS" -OutFile $sums
        }
        catch { return & $die "cannot download Vigil ${Want}: is there such a release?" }
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
        & $shell -NoProfile -ExecutionPolicy Bypass -File $script -Upgrade -Prefix $Root -Version $Want
        if ($LASTEXITCODE -ne 0) { return 1 }
    }
    finally {
        $ProgressPreference = $saved
        if ($work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
