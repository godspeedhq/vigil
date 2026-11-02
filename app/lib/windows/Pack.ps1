#Requires -Version 5.1

<#
.SYNOPSIS
    Vigil packs - Windows PowerShell 5.1 compatible.
.DESCRIPTION
    A pack is a set of scripts and jobs from the vigil-packs releases
    (SPECIFICATION.md 18.10). A release holds every pack, signed with the
    Vigil release key. A pack lives in packs\<name>\, which is Vigil's to
    replace, and its jobs are a marked block in the configuration, which is
    the operator's to edit: an update keeps what is there, adds the pack's
    new jobs and takes out those it dropped. The twin of pack.sh.

    Get-VigilPackList -Root <dir>
        What is added here.
    Add-VigilPack -Root <dir> -App <app dir> -Name <name>
    Update-VigilPack -Root <dir> -App <app dir> -Check <bool>
    Remove-VigilPack -Root <dir> -Name <name>
        Each returns an exit code: 0, or 1 with the reason on stderr; nothing
        is changed then.

    Requires Config.ps1, Validate.ps1 and SelfUpdate.ps1.
#>

$Script:VigilPackReleases = 'https://github.com/godspeedhq/vigil-packs'

function Stop-VigilPack {
    param([string]$Why)
    [Console]::Error.WriteLine("vigil: $Why")
}

function Get-VigilPackStart { param([string]$Name) "# pack ${Name}: added by vigil pack add; vigil pack remove takes it out" }
function Get-VigilPackEnd { param([string]$Name) "# end of pack $Name" }

# Reads a pack's manifest: @{ Version; Vigil; About; Jobs; Sections }, the jobs
# with a script for this platform, in order, each with its section's lines;
# $null when it cannot be read.
function Read-VigilPack {
    param([string]$Dir, [string]$Name)
    $f = Join-Path $Dir 'pack.config'
    if (-not [System.IO.File]::Exists($f)) { return $null }
    $p = ConvertFrom-VigilConfig -Path $f
    if ($p.Errors.Count -gt 0) { return $null }
    $r = @{ Version = ''; Vigil = ''; About = ''; Jobs = (New-Object 'System.Collections.Generic.List[string]'); Sections = @{} }
    foreach ($s in $p.Sections) {
        if ($s.Name -ceq 'pack') {
            $r.Version = Get-VigilConfigValue $p 'pack' 'version' ''
            $r.Vigil = Get-VigilConfigValue $p 'pack' 'vigil' ''
            $r.About = Get-VigilConfigValue $p 'pack' 'description' ''
        }
        elseif ($s.Name.StartsWith('job.', [System.StringComparison]::Ordinal)) {
            $job = $s.Name.Substring(4)
            if (-not [System.IO.File]::Exists((Join-Path $Dir "$job.ps1"))) { continue }
            $text = New-Object 'System.Collections.Generic.List[string]'
            $text.Add("[job.${Name}_$job]")
            $text.Add("file = packs/$Name/$job.ps1")
            foreach ($e in $p.Entries) {
                if ($e.Section -ceq $s.Name -and $e.Key -cne 'metrics' -and $e.Key -cne 'file') { $text.Add("$($e.Key) = $($e.Value)") }
            }
            $r.Jobs.Add($job)
            $r.Sections[$job] = $text
        }
    }
    if (-not $r.Version) { return $null }
    return $r
}

# Finds the latest release and unpacks it, verified: the signature against the
# key installed here, then the archive against SHA256SUMS. @{ Ok; Work; Src;
# Want }; the caller removes Work.
function Get-VigilPackRelease {
    param([string]$App)
    $out = @{ Ok = $false; Work = ''; Src = ''; Want = '' }
    $base = $Script:VigilPackReleases
    # Tests only (22.4.4): releases from a local server, never over the
    # network.
    if ($env:VIGIL_TEST_RELEASE_URL) {
        if ($env:VIGIL_TEST_RELEASE_URL -cnotmatch '^http://127\.0\.0\.1:[0-9]+$') { Stop-VigilPack 'VIGIL_TEST_RELEASE_URL must be http://127.0.0.1:<port>'; return $out }
        $base = "$env:VIGIL_TEST_RELEASE_URL/packs"
    }
    $key = Join-Path $App 'release-key.pem'
    if ($env:VIGIL_TEST_RELEASE_URL -and $env:VIGIL_TEST_RELEASE_KEY) { $key = $env:VIGIL_TEST_RELEASE_KEY }
    if (-not (Test-Path -LiteralPath $key)) { Stop-VigilPack 'no release key here: a pack cannot be verified; nothing was changed'; return $out }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $saved = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        try {
            $r = Invoke-WebRequest -UseBasicParsing -Method Head -TimeoutSec 60 -Uri "$base/releases/latest"
            $tag = if ($r.BaseResponse.ResponseUri) { [string]$r.BaseResponse.ResponseUri.AbsoluteUri } else { [string]$r.BaseResponse.RequestMessage.RequestUri.AbsoluteUri }
        }
        catch { Stop-VigilPack 'cannot reach GitHub to find the latest packs'; return $out }
        if ($tag -cnotmatch '/v([^/]+)$') { Stop-VigilPack "cannot tell the latest packs from $tag"; return $out }
        $want = $Matches[1]
        $work = Join-Path ([System.IO.Path]::GetTempPath()) "vigil-pack.$PID"
        if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
        [void](New-Item -ItemType Directory -Path $work)
        $out.Work = $work
        $file = "vigil-packs-$want.zip"
        try {
            foreach ($f in @($file, 'SHA256SUMS', 'SHA256SUMS.sig')) {
                Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -Uri "$base/releases/download/v$want/$f" -OutFile (Join-Path $work $f)
            }
        }
        catch { Stop-VigilPack "cannot download the packs $want"; return $out }
        $sums = Join-Path $work 'SHA256SUMS'
        if (-not (Test-VigilSignature -KeyFile $key -Data ([System.IO.File]::ReadAllBytes($sums)) -Signature ([System.IO.File]::ReadAllBytes((Join-Path $work 'SHA256SUMS.sig'))))) {
            Stop-VigilPack "the packs $want are not signed by the Vigil release key; nothing was changed"
            return $out
        }
        $sum = ''
        foreach ($l in [System.IO.File]::ReadAllLines($sums)) {
            $x = $l -split '\s+', 2
            if ($x.Count -eq 2 -and $x[1].TrimStart('*') -ceq $file) { $sum = $x[0].ToLowerInvariant() }
        }
        if (-not $sum -or (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $work $file)).Hash.ToLowerInvariant() -cne $sum) {
            Stop-VigilPack "the packs $want do not match their SHA256SUMS; nothing was changed"
            return $out
        }
        try { Expand-Archive -LiteralPath (Join-Path $work $file) -DestinationPath (Join-Path $work 'x') -ErrorAction Stop }
        catch { Stop-VigilPack "cannot unpack the packs $want"; return $out }
        $src = Join-Path $work "x\vigil-packs-$want"
        if (-not [System.IO.Directory]::Exists($src)) { Stop-VigilPack "the packs $want hold no vigil-packs-$want folder"; return $out }
        # Verified: the downloaded-from-the-internet mark would make a
        # RemoteSigned policy refuse them.
        Get-ChildItem -LiteralPath $src -Recurse -File | Unblock-File
        $out.Src = $src
        $out.Want = $want
        $out.Ok = $true
        return $out
    }
    finally { $ProgressPreference = $saved }
}

# What may stop an edit of the configuration, before anything is fetched.
function Test-VigilPackWritable {
    param([string]$Root)
    $cfg = Join-Path $Root 'config\vigil.config'
    $p = ConvertFrom-VigilConfig -Path $cfg
    if ($p.Errors.Count -gt 0) { Stop-VigilPack "$cfg has errors: fix them first (vigil precheck)"; return $false }
    $src = Get-VigilConfigValue $p 'vigil' 'config_source' ''
    if ($src) { Stop-VigilPack "the configuration comes from [source.$src]: add the pack's jobs there"; return $false }
    $probe = Join-Path $Root ".vigil-pack.$PID"
    try {
        [System.IO.File]::WriteAllText($probe, '')
        [System.IO.File]::Delete($probe)
        ([System.IO.File]::Open($cfg, 'Open', 'Write', 'ReadWrite')).Dispose()
    }
    catch { Stop-VigilPack "$Root is not writable: run this from an elevated prompt for a system install"; return $false }
    return $true
}

# Why the configuration now in place is not good for a pack, judged by the
# pack's own jobs, so a problem that was already there stops nothing; '' when
# it is good.
function Get-VigilPackProblem {
    param([string]$Root, [string]$Name)
    $p = ConvertFrom-VigilConfig -Path (Join-Path $Root 'config\vigil.config')
    if ($p.Errors.Count -gt 0) { return [string]$p.Errors[0].Message }
    foreach ($r in @(Test-VigilConfig -Parsed $p)) {
        if ($r.Kind -ceq 'ERROR' -or ($r.Kind -ceq 'INVALID' -and $r.Job.StartsWith("${Name}_", [System.StringComparison]::Ordinal))) { return "$($r.Message) ($($r.Code))" }
    }
    return ''
}

# The configuration with a pack's block changed: jobs the pack no longer has
# are taken out, and those missing added. With -Remove, the block goes.
# Sections the operator edited stay as they are.
function Get-VigilPackRewrite {
    param([string]$Text, [string]$Name, $Pack, [switch]$Remove)
    $start = Get-VigilPackStart $Name
    $end = Get-VigilPackEnd $Name
    $lines = $Text.Split("`n")
    $count = $lines.Length
    if ($count -gt 0 -and $lines[$count - 1] -ceq '') { $count-- }
    $out = New-Object 'System.Collections.Generic.List[string]'
    $in = $false; $keep = $true
    $seen = @{}
    for ($i = 0; $i -lt $count; $i++) {
        $line = $lines[$i]
        $bare = $line.TrimEnd("`r")
        if (-not $in) {
            if ($bare -ceq $start) {
                $in = $true
                $keep = $true
                if (-not $Remove) { $out.Add($line) }
            }
            else { $out.Add($line) }
            continue
        }
        if ($bare -ceq $end) {
            $in = $false
            if (-not $Remove) {
                foreach ($j in $Pack.Jobs) {
                    if ($seen.ContainsKey($j)) { continue }
                    $out.Add('')
                    foreach ($t in $Pack.Sections[$j]) { $out.Add($t) }
                }
                $out.Add($line)
            }
            continue
        }
        if ($Remove) { continue }
        if ($bare.StartsWith("[job.${Name}_", [System.StringComparison]::Ordinal)) {
            $job = $bare.Substring(6 + $Name.Length).Split(']')[0]
            $keep = $Pack.Jobs.Contains($job)
            if ($keep) { $seen[$job] = $true }
        }
        if ($keep) { $out.Add($line) }
    }
    return (($out -join "`n") + "`n")
}

# Windows refuses to rename a folder while a process has a file in it open,
# and a job reads its script as it starts, so the refusal lasts a moment.
function Move-VigilPackFolder {
    param([string]$From, [string]$To)
    for ($i = 0; ; $i++) {
        try { [System.IO.Directory]::Move($From, $To); return }
        catch {
            if ($i -ge 120) { throw }
            Start-Sleep -Milliseconds 250
        }
    }
}

# Puts a pack in place and changes the configuration; goes back when the
# result is not valid. Returns whether it worked.
function Set-VigilPack {
    param([string]$Root, [string]$Name, [string]$Src, [string]$Text)
    $cfg = Join-Path $Root 'config\vigil.config'
    $packs = Join-Path $Root 'packs'
    $dir = Join-Path $packs $Name
    [void](New-Item -ItemType Directory -Force -Path $packs)
    foreach ($p in @("$dir.new", "$dir.old")) { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force } }
    try { Copy-Item -LiteralPath $Src -Destination "$dir.new" -Recurse -ErrorAction Stop }
    catch {
        Remove-Item -LiteralPath "$dir.new" -Recurse -Force -ErrorAction SilentlyContinue
        Stop-VigilPack "cannot write to $packs; nothing was changed"
        return $false
    }
    $before = [System.IO.File]::ReadAllText($cfg)
    $had = [System.IO.Directory]::Exists($dir)
    if ($had) { Move-VigilPackFolder $dir "$dir.old" }
    Move-VigilPackFolder "$dir.new" $dir
    [System.IO.File]::WriteAllText($cfg, $Text)
    $why = Get-VigilPackProblem -Root $Root -Name $Name
    if ($why) {
        [System.IO.File]::WriteAllText($cfg, $before)
        Remove-Item -LiteralPath $dir -Recurse -Force
        if ($had) { Move-VigilPackFolder "$dir.old" $dir }
        Stop-VigilPack "pack $Name would not be valid here: $why; nothing was changed"
        return $false
    }
    if ($had) { Remove-Item -LiteralPath "$dir.old" -Recurse -Force -ErrorAction SilentlyContinue }
    return $true
}

# Adds or updates a pack from the verified release. Returns an exit code.
function Install-VigilPack {
    param([string]$Root, [string]$App, [string]$Name, $Release, [bool]$Add)
    $src = Join-Path $Release.Src $Name
    $m = Read-VigilPack -Dir $src -Name $Name
    if (-not $m) { Stop-VigilPack "no pack called $Name in the packs $($Release.Want)"; return 1 }
    $ver = Join-Path $App 'VERSION'
    if ($m.Vigil -and [System.IO.File]::Exists($ver) -and (Test-VigilNewer $m.Vigil ([System.IO.File]::ReadAllText($ver).Trim()))) {
        Stop-VigilPack "pack $Name needs Vigil $($m.Vigil) or later: vigil self update"
        return 1
    }
    $text = [System.IO.File]::ReadAllText((Join-Path $Root 'config\vigil.config'))
    if ($Add) {
        $b = New-Object 'System.Collections.Generic.List[string]'
        $b.Add('')
        $b.Add((Get-VigilPackStart $Name))
        foreach ($j in $m.Jobs) {
            foreach ($t in $m.Sections[$j]) { $b.Add($t) }
            $b.Add('')
        }
        $b.Add((Get-VigilPackEnd $Name))
        if (-not $text.EndsWith("`n")) { $text += "`n" }
        $new = $text + (($b -join "`n") + "`n")
    }
    else { $new = Get-VigilPackRewrite -Text $text -Name $Name -Pack $m }
    if (-not (Set-VigilPack -Root $Root -Name $Name -Src $src -Text $new)) { return 1 }
    Write-Output "pack $Name $($m.Version): jobs$(@($m.Jobs | ForEach-Object { " ${Name}_$_" }) -join '')"
    return 0
}

function Get-VigilPackList {
    param([string]$Root)
    $packs = Join-Path $Root 'packs'
    $n = 0
    if ([System.IO.Directory]::Exists($packs)) {
        foreach ($d in ([System.IO.Directory]::GetDirectories($packs) | Sort-Object)) {
            $name = [System.IO.Path]::GetFileName($d)
            $m = Read-VigilPack -Dir $d -Name $name
            if (-not $m) { continue }
            Write-Output ('{0,-12} {1,-10} {2}' -f $name, $m.Version, $m.About).TrimEnd()
            $n++
        }
    }
    if ($n -eq 0) { Write-Output 'no packs added: vigil pack add base' }
}

function Add-VigilPack {
    param([string]$Root, [string]$App, [string]$Name)
    if ($Name -cnotmatch '^[a-z0-9_]+$') { Stop-VigilPack "not a pack name: $Name"; return 1 }
    if (-not [System.IO.File]::Exists((Join-Path $Root 'config\vigil.config'))) { Stop-VigilPack 'no configuration here: run vigil init first'; return 1 }
    if ([System.IO.Directory]::Exists((Join-Path $Root "packs\$Name"))) { Stop-VigilPack "pack $Name is already added: vigil pack update"; return 1 }
    if (-not (Test-VigilPackWritable -Root $Root)) { return 1 }
    $rel = Get-VigilPackRelease -App $App
    try {
        if (-not $rel.Ok) { return 1 }
        return Install-VigilPack -Root $Root -App $App -Name $Name -Release $rel -Add $true
    }
    finally { if ($rel.Work) { Remove-Item -LiteralPath $rel.Work -Recurse -Force -ErrorAction SilentlyContinue } }
}

function Update-VigilPack {
    param([string]$Root, [string]$App, [bool]$Check)
    $packs = Join-Path $Root 'packs'
    $names = @()
    if ([System.IO.Directory]::Exists($packs)) {
        $names = @([System.IO.Directory]::GetDirectories($packs) | Sort-Object | Where-Object { [System.IO.File]::Exists((Join-Path $_ 'pack.config')) } |
                ForEach-Object { [System.IO.Path]::GetFileName($_) })
    }
    if ($names.Count -eq 0) { Write-Output 'no packs added: vigil pack add base'; return 0 }
    if (-not $Check -and -not (Test-VigilPackWritable -Root $Root)) { return 1 }
    $rel = Get-VigilPackRelease -App $App
    $code = 0
    try {
        if (-not $rel.Ok) { return 1 }
        foreach ($name in $names) {
            $was = Read-VigilPack -Dir (Join-Path $packs $name) -Name $name
            if (-not $was) { continue }
            $now = Read-VigilPack -Dir (Join-Path $rel.Src $name) -Name $name
            if (-not $now) { Write-Output "pack $name is no longer in the packs $($rel.Want): left as it is" }
            elseif ($now.Version -ceq $was.Version) { Write-Output "pack $name $($was.Version) is added: nothing to do" }
            elseif ($Check) { Write-Output "pack $name $($was.Version) is added; $($now.Version) is available: vigil pack update" }
            else {
                Install-VigilPack -Root $Root -App $App -Name $name -Release $rel -Add $false | ForEach-Object {
                    if ($_ -is [int]) { if ($_ -ne 0) { $code = 1 } } else { $_ }
                }
            }
        }
        return $code
    }
    finally { if ($rel.Work) { Remove-Item -LiteralPath $rel.Work -Recurse -Force -ErrorAction SilentlyContinue } }
}

function Remove-VigilPack {
    param([string]$Root, [string]$Name)
    if ($Name -cnotmatch '^[a-z0-9_]+$') { Stop-VigilPack "not a pack name: $Name"; return 1 }
    $dir = Join-Path $Root "packs\$Name"
    if (-not [System.IO.Directory]::Exists($dir)) { Stop-VigilPack "pack $Name is not added"; return 1 }
    if (-not (Test-VigilPackWritable -Root $Root)) { return 1 }
    $cfg = Join-Path $Root 'config\vigil.config'
    $before = [System.IO.File]::ReadAllText($cfg)
    [System.IO.File]::WriteAllText($cfg, (Get-VigilPackRewrite -Text $before -Name $Name -Pack $null -Remove))
    $why = Get-VigilPackProblem -Root $Root -Name $Name
    if ($why) {
        [System.IO.File]::WriteAllText($cfg, $before)
        Stop-VigilPack "the configuration would not be valid without pack ${Name}: $why; nothing was changed"
        return 1
    }
    Remove-Item -LiteralPath $dir -Recurse -Force
    Write-Output "removed pack $Name"
    return 0
}
