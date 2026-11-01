#Requires -Version 5.1

<#
.SYNOPSIS
    Vigil fetcher - Windows PowerShell 5.1 compatible.
.DESCRIPTION
    Sources and reconciliation (SPECIFICATION.md 6.8, 6.9, 16.5): the body
    of the vigil_fetch worker, and the activation record the supervisor,
    workers and pre-flight read. The twin of fetch.sh.

    Invoke-VigilFetch -Ctx <worker context> -HostName <name> -Root <dir> -Log <file>
        Called by the worker after its claim, with the local configuration
        in the context. Fetches what the candidate configuration needs,
        verifies it, and activates it by writing state\config.active.
        Returns @{ Ok; Reason }; on failure nothing that is active changes.
    Test-VigilFetchMode -Parsed <parsed>
        Whether the configuration needs the fetcher: it is a pointer file
        (6.8) or defines a source (6.9).
    Read-VigilActive -Root <dir> -State <dir>
        The activation record as @{ Config; Revision; Origin; Scripts }, each
        script @{ Source; Entry; Sha; File }, or $null when there is none or
        its configuration file is missing.
    Get-VigilActiveScript -Root <dir> -Active <record> -Source <name> -File <file>
        The cached copy of a script the record names, or $null.

    Each configuration activated is kept as state\configs\<sha256>.config,
    so deleting the cache never loses the last valid one. The cache is
    <root>\cache, with cache\<source>\<entry>\ for each source, where the
    entry is a git commit, the digest of a local directory's contents, or
    the digest of a file fetched over https or sftp. Entries are assembled
    under cache\staging\ and renamed into place, so each is complete or
    absent.

    Requires Config.ps1, Validate.ps1, Worker.ps1, Secrets.ps1, Stores.ps1
    and Precheck.ps1.
#>

$Script:VigilFetchConfigMax = 1048576
$Script:VigilFetchScriptMax = 16777216

function Test-VigilFetchMode {
    param($Parsed)
    foreach ($s in $Parsed.Sections) { if ($s.Name.StartsWith('source.', [System.StringComparison]::Ordinal)) { return $true } }
    return (Get-VigilConfigValue $Parsed 'vigil' 'config_source' '').Length -gt 0
}

function Read-VigilActive {
    param([string]$Root, [string]$State)
    $f = Join-Path $State 'config.active'
    if (-not [System.IO.File]::Exists($f)) { return $null }
    $a = @{ Config = ''; Revision = ''; Origin = ''; Scripts = New-Object 'System.Collections.Generic.List[object]' }
    foreach ($l in [System.IO.File]::ReadAllLines($f)) {
        if ($l -cnotmatch '^(\w+) += (.*)$') { continue }
        $v = $Matches[2]
        switch -CaseSensitive ($Matches[1]) {
            'revision' { $a.Revision = $v }
            'origin' { $a.Origin = $v }
            'config' { $a.Config = Join-Path $State "configs\$v.config" }
            'script' {
                # <source> <entry> <sha256> <file>: the file last, since it
                # may hold spaces.
                $p = $v.Split(' ', 4)
                if ($p.Count -eq 4) { $a.Scripts.Add(@{ Source = $p[0]; Entry = $p[1]; Sha = $p[2]; File = $p[3] }) }
            }
        }
    }
    if (-not $a.Config -or -not [System.IO.File]::Exists($a.Config)) { return $null }
    return $a
}

function Get-VigilActiveScript {
    param([string]$Root, $Active, [string]$Source, [string]$File)
    if (-not $Active) { return $null }
    foreach ($s in $Active.Scripts) {
        if ($s.Source -ceq $Source -and $s.File -ceq $File) {
            return Join-Path $Root ("cache\$Source\$($s.Entry)\" + $File.Replace('/', '\'))
        }
    }
    return $null
}

# The SHA-256 of a file or of text, as 64 lower-case hex digits.
function Get-VigilFileSha {
    param([string]$Path)
    $h = [System.Security.Cryptography.SHA256]::Create()
    $fs = [System.IO.File]::OpenRead($Path)
    try { return ([System.BitConverter]::ToString($h.ComputeHash($fs)) -replace '-', '').ToLowerInvariant() }
    finally { $fs.Dispose(); $h.Dispose() }
}

function Get-VigilTextSha {
    param([string]$Text)
    $h = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($h.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))) -replace '-', '').ToLowerInvariant() }
    finally { $h.Dispose() }
}

<#
    Runs a program with a time limit, never through a shell. Returns
    @{ Code; Out; Err; TimedOut }; at the limit its process tree is ended.
#>
function Invoke-VigilFetchProcess {
    param([string]$Program, [string[]]$Arguments, [int]$Seconds, [string]$WorkDir, [hashtable]$Environment)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Program
    $psi.Arguments = ($Arguments | ForEach-Object { ConvertTo-VigilQuotedArg -Arg $_ -Always $false }) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    if ($WorkDir) { $psi.WorkingDirectory = $WorkDir }
    if ($Environment) { foreach ($k in $Environment.Keys) { $psi.EnvironmentVariables[$k] = $Environment[$k] } }
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($Seconds * 1000)) {
        & taskkill.exe /T /F /PID $p.Id 2>&1 | Out-Null
        [void]$p.WaitForExit(5000)
        return @{ Code = -1; Out = ''; Err = ''; TimedOut = $true }
    }
    $p.WaitForExit()
    return @{ Code = $p.ExitCode; Out = $outTask.Result; Err = $errTask.Result; TimedOut = $false }
}

# The first line of a program's error output, for a failure reason.
function Get-VigilFirstLine {
    param([string]$Text)
    $l = @($Text.Split("`n") | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_ })[0]
    if (-not $l) { return '' }
    if ($l.Length -gt 200) { $l = $l.Substring(0, 200) }
    return $l
}

# A program on the PATH, or $null.
function Find-VigilProgram {
    param([string]$Name)
    $c = @(Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue)[0]
    if ($c) { return $c.Source }
    return $null
}

# A source's settings from a parsed configuration.
function Get-VigilFetchSource {
    param($Parsed, [string]$Name)
    $sec = "source.$Name"
    $g = { param($k, $d) Get-VigilConfigValue $Parsed $sec $k $d }
    $s = @{
        Name = $Name; Type = & $g 'type' ''; Url = & $g 'url' ''; Path = & $g 'path' ''; Host = & $g 'host' ''
        Port = & $g 'port' '22'; User = & $g 'user' ''; Ref = & $g 'ref' ''; HName = & $g 'header_name' ''
        HValue = & $g 'header_value' ''; Check = & $g 'check_every' '5m'; Timeout = & $g 'timeout' '60s'
    }
    $s.Every = ConvertTo-VigilSeconds $s.Check
    $s.Secs = ConvertTo-VigilSeconds $s.Timeout
    # What the source's content depends on: a change refetches it.
    $s.Identity = "$($s.Type) $($s.Url)$($s.Path) $($s.Host):$($s.Port) $($s.User) $($s.Ref)"
    return $s
}

# Whether a link at Path with Target stays inside the tree it is in: the
# link's directory, then the target from there, never above the top.
function Test-VigilLinkInside {
    param([string]$Path, [string]$Target)
    if ($Target.StartsWith('/') -or $Target.Contains('\') -or $Target -cmatch '^[A-Za-z]:') { return $false }
    $dir = if ($Path.Contains('/')) { $Path.Substring(0, $Path.LastIndexOf('/')) } else { '' }
    $depth = 0
    foreach ($seg in "$dir/$Target".Split('/')) {
        if ($seg -ceq '' -or $seg -ceq '.') { continue }
        if ($seg -ceq '..') { $depth--; if ($depth -lt 0) { return $false } }
        else { $depth++ }
    }
    return $true
}

function Invoke-VigilFetch {
    param($Ctx, [string]$HostName, [string]$Root, [string]$Log)
    $state = $Ctx.State
    $cache = Join-Path $Root 'cache'
    $st = Join-Path $cache 'staging'
    $configs = Join-Path $state 'configs'
    $f = @{
        Now = [DateTimeOffset]::Now.ToUnixTimeSeconds(); Next = $null; Failed = ''
        FailedNames = New-Object 'System.Collections.Generic.HashSet[string]'
        Events = New-Object 'System.Collections.Generic.List[string]'
        Synced = @{}; Tags = ''
    }
    if ([System.IO.Directory]::Exists($st)) { [System.IO.Directory]::Delete($st, $true) }
    [void](New-Item -ItemType Directory -Force -Path $st, $configs, (Join-Path $state 'sources'))
    $localPath = Join-Path $Root 'config\vigil.config'
    $local = Get-VigilFileSha $localPath

    $note = {
        param([string]$Text)
        $iso = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
        try { [System.IO.File]::AppendAllText($Log, "$iso $Text`r`n") } catch { }
    }
    $tagsOf = {
        param($Parsed)
        $t = "host=$HostName os=windows instance=$(Get-VigilConfigValue $Parsed 'vigil' 'instance' 'vigil')"
        foreach ($e in $Parsed.Entries) { if ($e.Section -ceq 'tags') { $t += " $($e.Key)=$($e.Value)" } }
        return $t
    }
    # Records a failure of a source, once per run. The event's reason tag
    # sorts it (14.5).
    $failed = {
        param([string]$Name, [string]$Why)
        if (-not $f.FailedNames.Add($Name)) { return }
        $f.Failed += $(if ($f.Failed) { '; ' } else { '' }) + "source.${Name}: $Why"
        $reason = 'unreachable'
        if ($Why.Contains('timed out')) { $reason = 'timeout' }
        elseif ($Why -cmatch 'permission denied|Permission denied|Host key verification failed|Authentication failed|could not read Username') { $reason = 'auth' }
        elseif ($Why.Contains('does not match its sha256')) { $reason = 'digest' }
        elseif ($Why -cmatch '(has errors| not found|not found \(HTTP 404\))$|symbolic link|larger than') { $reason = 'invalid' }
        $f.Events.Add("$($f.Now) vigil.source.failures 1 count $($f.Tags) source=$Name reason=$reason")
        & $note "source.${Name}: $Why"
    }
    $next = {
        param([long]$At)
        if ($null -eq $f.Next -or $At -lt $f.Next) { $f.Next = $At }
    }

    # A source's fetch state.
    $readState = {
        param([string]$Name)
        $s = @{ identity = ''; checked_epoch = '0'; ok_epoch = ''; entry = ''; kind = ''; failures = '0' }
        $p = Join-Path $state "sources\$Name.state"
        if ([System.IO.File]::Exists($p)) {
            foreach ($l in [System.IO.File]::ReadAllLines($p)) {
                if ($l -cmatch '^(\w+) *=( (.*))?$' -and $s.ContainsKey($Matches[1])) { $s[$Matches[1]] = [string]$Matches[3] }
            }
        }
        return $s
    }
    $writeState = {
        param([string]$Name, $S, [string]$Why)
        $text = "[source]`nidentity      = $($S.identity)`nchecked_epoch = $($S.checked_epoch)`nok_epoch      = $($S.ok_epoch)`nentry         = $($S.entry)`n" +
            "kind          = $($S.kind)`nfailures      = $($S.failures)`nerror         = $Why`n"
        Write-VigilFileAtomic -Path (Join-Path $state "sources\$Name.state") -Text $text
    }

    # Moves a staged directory into the cache as an entry, unless it is
    # there already.
    $place = {
        param([string]$Staged, [string]$Name, [string]$Entry)
        $dest = Join-Path $cache "$Name\$Entry"
        if ([System.IO.Directory]::Exists($dest)) { [System.IO.Directory]::Delete($Staged, $true); return }
        [void](New-Item -ItemType Directory -Force -Path (Join-Path $cache $Name))
        try { [System.IO.Directory]::Move($Staged, $dest) }
        catch { if (-not [System.IO.Directory]::Exists($dest)) { throw } }
    }

    # git: fetch into the bare mirror, resolve the ref and unpack its tree.
    $syncGit = {
        param($S)
        $git = Find-VigilProgram 'git'
        if (-not $git) { return @{ Why = 'git not found' } }
        $mirror = Join-Path $cache "$($S.Name)\repo.git"
        [void](New-Item -ItemType Directory -Force -Path (Join-Path $cache $S.Name))
        if (-not [System.IO.Directory]::Exists($mirror)) {
            $r = Invoke-VigilFetchProcess $git @('init', '-q', '--bare', $mirror) 60
            if ($r.Code -ne 0) { return @{ Why = "cannot create $mirror" } }
        }
        # Nothing is checked out, so no hook, filter or submodule ever runs.
        # Credentials come from the account's credential helper or SSH key;
        # nothing may stop to ask for one.
        $r = Invoke-VigilFetchProcess $git @("--git-dir=$mirror", '-c', 'core.hooksPath=NUL', 'fetch', '-q', '--no-tags', '--no-recurse-submodules',
            '--force', $S.Url, '+refs/heads/*:refs/heads/*', '+refs/tags/*:refs/tags/*') $S.Secs '' @{ GIT_TERMINAL_PROMPT = '0'; GCM_INTERACTIVE = 'never' }
        if ($r.TimedOut) { return @{ Why = "timed out after $($S.Timeout)" } }
        if ($r.Code -ne 0) {
            $l = Get-VigilFirstLine $r.Err
            return @{ Why = "git fetch failed: $(if ($l) { $l } else { "exit code $($r.Code)" })" }
        }
        $resolve = {
            param([string]$Ref)
            $x = Invoke-VigilFetchProcess $git @("--git-dir=$mirror", 'rev-parse', '-q', '--verify', $Ref) 60
            if ($x.Code -eq 0) { return $x.Out.Trim() }
            return ''
        }
        $kind = 'tag'
        $commit = & $resolve "refs/tags/$($S.Ref)^{commit}"
        if (-not $commit) { $kind = 'branch'; $commit = & $resolve "refs/heads/$($S.Ref)^{commit}" }
        if (-not $commit -and $S.Ref -cmatch '^[0-9a-f]{7,64}$') { $kind = 'commit'; $commit = & $resolve "$($S.Ref)^{commit}" }
        if (-not $commit) { return @{ Why = "ref '$($S.Ref)' not found" } }
        if ([System.IO.Directory]::Exists((Join-Path $cache "$($S.Name)\$commit"))) { return @{ Entry = $commit; Kind = $kind } }
        $x = Invoke-VigilFetchProcess $git @("--git-dir=$mirror", 'ls-tree', '-r', '-z', $commit) 60
        foreach ($rec in $x.Out.Split([char]0)) {
            if (-not $rec.StartsWith('120000 ', [System.StringComparison]::Ordinal)) { continue }
            $tab = $rec.IndexOf("`t")
            $oid = $rec.Substring(0, $tab).Split(' ')[2]
            $path = $rec.Substring($tab + 1)
            $target = (Invoke-VigilFetchProcess $git @("--git-dir=$mirror", 'cat-file', 'blob', $oid) 60).Out
            if (-not (Test-VigilLinkInside $path $target)) {
                return @{ Why = "'$path' at $($S.Ref) is a symbolic link pointing outside the repository" }
            }
        }
        $zip = Join-Path $st 'tree.zip'
        $tree = Join-Path $st 'tree'
        $x = Invoke-VigilFetchProcess $git @("--git-dir=$mirror", '-c', 'core.autocrlf=false', 'archive', '--format=zip', '-o', $zip, $commit) $S.Secs
        if ($x.Code -ne 0) { return @{ Why = "cannot unpack ${commit}: $(Get-VigilFirstLine $x.Err)" } }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        try { [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $tree) }
        catch { return @{ Why = "cannot unpack ${commit}: $($_.Exception.Message)" } }
        [System.IO.File]::Delete($zip)
        & $place $tree $S.Name $commit
        return @{ Entry = $commit; Kind = $kind }
    }

    # local: a copy of the directory, so a job never runs a file from a
    # share that may change under it. The entry is named by its contents.
    $syncLocal = {
        param($S)
        $dir = $S.Path.Replace('/', '\')
        if (-not [System.IO.Path]::IsPathRooted($dir)) { $dir = Join-Path $Root $dir }
        if (-not [System.IO.Directory]::Exists($dir)) { return @{ Why = "not a directory: $dir" } }
        $tree = Join-Path $st 'tree'
        $r = Invoke-VigilFetchProcess (Join-Path $env:SystemRoot 'System32\robocopy.exe') @($dir, $tree, '/E', '/R:0', '/W:0', '/NFL', '/NDL', '/NJH', '/NJS', '/NP') $S.Secs
        if ($r.TimedOut) { return @{ Why = "timed out after $($S.Timeout)" } }
        if ($r.Code -ge 8) { return @{ Why = "cannot copy ${dir}: $(Get-VigilFirstLine $r.Out)" } }
        [void](New-Item -ItemType Directory -Force -Path $tree)
        $lines = New-Object 'System.Collections.Generic.List[string]'
        foreach ($file in [System.IO.Directory]::GetFiles($tree, '*', 'AllDirectories')) {
            $lines.Add('./' + $file.Substring($tree.Length + 1).Replace('\', '/'))
        }
        $lines.Sort([System.StringComparer]::Ordinal)
        $sb = New-Object System.Text.StringBuilder
        foreach ($l in $lines) { [void]$sb.Append("$(Get-VigilFileSha (Join-Path $tree $l.Substring(2))) $l`n") }
        $digest = Get-VigilTextSha $sb.ToString()
        & $place $tree $S.Name $digest
        return @{ Entry = $digest; Kind = '' }
    }

    # https: GET <url>/<file>, with the source's header. Plain http only to
    # this host (as for a metrics backend, 15.3); redirects are not followed.
    $getHttps = {
        param($S, [string]$File, [string]$Out, [long]$Max)
        $url = $S.Url
        if (-not $url.EndsWith('/')) { $url += '/' }
        $url += (($File.Split('/') | ForEach-Object { [System.Uri]::EscapeDataString($_) }) -join '/')
        $hostPart = ($S.Url -replace '^[a-z]+://', '').Split('/')[0]
        $plain = $S.Url -cmatch '^http://(localhost|127\.0\.0\.1|\[::1\])([:/]|$)'
        if (-not $plain -and -not $S.Url.StartsWith('https://', [System.StringComparison]::Ordinal)) { return 'only https is allowed' }
        $hv = $null
        if ($S.HName) {
            $sec = Resolve-VigilSecret -Root $Root -Parsed $Ctx.Parsed -Reference $S.HValue
            if (-not $sec.Ok) { return "header_value $($S.HValue) unavailable: $($sec.Why)" }
            $hv = $sec.Value
            if ($hv -cmatch '[\x00-\x1f\x7f]') { return "header_value $($S.HValue) holds a control character" }
        }
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.Method = 'GET'
        $req.Timeout = $S.Secs * 1000
        $req.ReadWriteTimeout = $S.Secs * 1000
        $req.AllowAutoRedirect = $false
        if ($plain) { $req.Proxy = $null }
        if ($S.HName) { $req.Headers.Add($S.HName, $hv) }
        $hv = $null
        $resp = $null
        try { $resp = $req.GetResponse() }
        catch {
            $e = $_.Exception
            while ($e -and -not ($e -is [System.Net.WebException])) { $e = $e.InnerException }
            if ($e -and $e.Response) { $resp = $e.Response }
            else {
                switch (Get-VigilHttpFailure $_.Exception) {
                    'resolve' { return "cannot resolve $hostPart" }
                    'connect' { return "cannot connect to $hostPart" }
                    'timeout' { return "timed out after $($S.Timeout)" }
                    'untrusted' { return "the certificate of $hostPart is not trusted" }
                    default { return "request to $hostPart failed" }
                }
            }
        }
        try {
            $code = [int]$resp.StatusCode
            if ($code -eq 401 -or $code -eq 403) { return "permission denied (HTTP $code)" }
            if ($code -eq 404) { return "$File not found (HTTP 404)" }
            if ($code -ne 200) { return "HTTP $code from $hostPart" }
            $in = $resp.GetResponseStream()
            $fs = [System.IO.File]::Create($Out)
            try {
                $buf = New-Object byte[] 65536
                $total = 0
                while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                    $total += $n
                    if ($total -gt $Max) { return "$File is larger than $Max bytes" }
                    $fs.Write($buf, 0, $n)
                }
            }
            finally { $fs.Dispose() }
            return ''
        }
        catch { return "request to $hostPart failed" }
        finally { $resp.Close() }
    }

    # sftp: the OpenSSH client in batch mode; the server's host key must
    # already be known. VIGIL_TEST_SSH_CONFIG gives tests their own ssh
    # configuration; the options on the command line take precedence.
    $getSftp = {
        param($S, [string]$File, [string]$Out)
        $sftp = Find-VigilProgram 'sftp'
        if (-not $sftp) { return 'sftp not found' }
        if ("$File$($S.Path)" -match '["\\]') { return 'cannot fetch a path containing " or \ over sftp' }
        $dest = if ($S.User) { "$($S.User)@$($S.Host)" } else { $S.Host }
        [System.IO.File]::WriteAllText((Join-Path $st 'batch'), "get `"$($S.Path.TrimEnd('/'))/$File`" download`n")
        $dl = Join-Path $st 'download'
        if ([System.IO.File]::Exists($dl)) { [System.IO.File]::Delete($dl) }
        $argv = @('-b', 'batch', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', "ConnectTimeout=$($S.Secs)", '-P', $S.Port)
        if ($env:VIGIL_TEST_SSH_CONFIG) { $argv += @('-F', $env:VIGIL_TEST_SSH_CONFIG) }
        $r = Invoke-VigilFetchProcess $sftp ($argv + @('--', $dest)) $S.Secs $st
        if ($r.TimedOut) { return "timed out after $($S.Timeout)" }
        if ($r.Code -ne 0 -or -not [System.IO.File]::Exists($dl)) {
            $l = Get-VigilFirstLine $r.Err
            return "sftp failed: $(if ($l) { $l } else { "exit code $($r.Code)" })"
        }
        Move-Item -LiteralPath $dl -Destination $Out -Force
        return ''
    }

    # Downloads a file of an https or sftp source, at most Max bytes.
    # Returns the reason it failed, or ''.
    $download = {
        param($S, [string]$File, [string]$Out, [long]$Max)
        if ([System.IO.File]::Exists($Out)) { [System.IO.File]::Delete($Out) }
        $why = if ($S.Type -ceq 'https') { & $getHttps $S $File $Out $Max } else { & $getSftp $S $File $Out }
        if ($why) { return $why }
        if ((New-Object System.IO.FileInfo $Out).Length -gt $Max) { return "$File is larger than $Max bytes" }
        return ''
    }

    # Brings a source up to date, once per run, when it is due: a git or
    # local source, or the configuration file of an https or sftp one.
    # Returns @{ Entry } or @{ Why }.
    $sync = {
        param($S, [string]$File)
        if ($f.Synced.ContainsKey($S.Name)) { return $f.Synced[$S.Name] }
        $ss = & $readState $S.Name
        $result = @{ Entry = $ss.entry }
        if ($ss.identity -cne $S.Identity -or -not $ss.entry -or
            -not [System.IO.Directory]::Exists((Join-Path $cache "$($S.Name)\$($ss.entry)")) -or
            ([long]$ss.checked_epoch + $S.Every) -le $f.Now) {
            switch -CaseSensitive ($S.Type) {
                'git' { $r = & $syncGit $S }
                'local' { $r = & $syncLocal $S }
                default {
                    $tmp = Join-Path $st 'config'
                    $why = & $download $S $File $tmp $Script:VigilFetchConfigMax
                    if ($why) { $r = @{ Why = $why } }
                    else {
                        $sha = Get-VigilFileSha $tmp
                        $dest = Join-Path $cache ("$($S.Name)\$sha\" + $File.Replace('/', '\'))
                        [void](New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($dest)))
                        Move-Item -LiteralPath $tmp -Destination $dest -Force
                        $r = @{ Entry = $sha; Kind = '' }
                    }
                }
            }
            $ss.checked_epoch = [string]$f.Now
            if ($r.Why) {
                $ss.failures = [string]([int]$ss.failures + 1)
                & $writeState $S.Name $ss $r.Why
                $result = @{ Why = $r.Why }
            }
            else {
                if ($r.Kind -ceq 'branch' -and $r.Entry -cne $ss.entry) {
                    & $note "WARN source.$($S.Name): ref '$($S.Ref)' is a branch: its scripts follow it, and hosts may briefly differ (W_SCRIPT_UNPINNED)"
                }
                $ss.identity = $S.Identity; $ss.entry = $r.Entry; $ss.kind = $r.Kind; $ss.failures = '0'; $ss.ok_epoch = [string]$f.Now
                & $writeState $S.Name $ss ''
                $result = @{ Entry = $r.Entry }
            }
        }
        & $next ([long]$ss.checked_epoch + $S.Every)
        $f.Synced[$S.Name] = $result
        return $result
    }

    # The verified copy the active record has of a file with this digest,
    # kept when the source's content no longer matches it.
    $keep = {
        param([string]$Src, [string]$File, [string]$Want)
        if (-not $f.Active) { return $null }
        foreach ($s in $f.Active.Scripts) {
            if ($s.Source -ceq $Src -and $s.File -ceq $File -and $s.Sha -ceq $Want -and
                [System.IO.File]::Exists((Join-Path $cache ("$Src\$($s.Entry)\" + $File.Replace('/', '\'))))) {
                & $note "WARN source.${Src}: $File no longer matches its sha256; the last verified copy stays in use"
                return @{ Entry = $s.Entry; Sha = $Want }
            }
        }
        return $null
    }

    # One script reference: Returns @{ Entry; Sha } or @{ Why }.
    $ref = {
        param($Parsed, [string]$Src, [string]$File, [string]$Want)
        $S = Get-VigilFetchSource $Parsed $Src
        $rel = $File.Replace('/', '\')
        if ($S.Type -ceq 'https' -or $S.Type -ceq 'sftp') {
            # Pinned by digest (6.9): a cached copy that verifies is final.
            $p = Join-Path $cache "$Src\$Want\$rel"
            if ([System.IO.File]::Exists($p) -and (Get-VigilFileSha $p) -ceq $Want) { return @{ Entry = $Want; Sha = $Want } }
            $tmp = Join-Path $st 'script'
            $why = & $download $S $File $tmp $Script:VigilFetchScriptMax
            if ($why) { return @{ Why = $why } }
            if ((Get-VigilFileSha $tmp) -cne $Want) { return @{ Why = "$File does not match its sha256" } }
            [void](New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($p)))
            Move-Item -LiteralPath $tmp -Destination $p -Force
            return @{ Entry = $Want; Sha = $Want }
        }
        $r = & $sync $S ''
        if ($r.Why) { return $r }
        $p = Join-Path $cache "$Src\$($r.Entry)\$rel"
        if (-not [System.IO.File]::Exists($p)) { return @{ Why = "$File not found" } }
        if ((New-Object System.IO.FileInfo $p).Length -gt $Script:VigilFetchScriptMax) { return @{ Why = "$File is larger than $($Script:VigilFetchScriptMax) bytes" } }
        $sha = Get-VigilFileSha $p
        if ($Want -and $sha -cne $Want) {
            $k = & $keep $Src $File $Want
            if ($k) { return $k }
            return @{ Why = "$File does not match its sha256" }
        }
        return @{ Entry = $r.Entry; Sha = $sha }
    }

    # Event tags come from the active configuration, else the local file.
    $f.Active = Read-VigilActive -Root $Root -State $state
    $f.Tags = if ($f.Active) { & $tagsOf (ConvertFrom-VigilConfig -Path $f.Active.Config) } else { & $tagsOf $Ctx.Parsed }

    # The candidate: the configuration from its source (6.8), or the local
    # file.
    $csrc = Get-VigilConfigValue $Ctx.Parsed 'vigil' 'config_source' ''
    $cfile = ''
    $cand = ''
    if ($csrc) {
        $cfile = Get-VigilConfigValue $Ctx.Parsed 'vigil' 'config_file' ''
        $origin = "source.$csrc $cfile"
        $r = & $sync (Get-VigilFetchSource $Ctx.Parsed $csrc) $cfile
        $p = Join-Path $cache ("$csrc\$($r.Entry)\" + $cfile.Replace('/', '\'))
        if ($r.Why) { & $failed $csrc $r.Why }
        elseif (-not [System.IO.File]::Exists($p)) { & $failed $csrc "$cfile not found" }
        elseif ((New-Object System.IO.FileInfo $p).Length -gt $Script:VigilFetchConfigMax) { & $failed $csrc "$cfile is larger than $($Script:VigilFetchConfigMax) bytes" }
        else { $cand = $p }
    }
    else {
        $origin = 'local'
        $cand = $localPath
    }

    $lines = ''
    $body = ''
    if (-not $f.Failed) {
        $sha = Get-VigilFileSha $cand
        $kept = Join-Path $configs "$sha.config"
        if (-not [System.IO.File]::Exists($kept)) { Write-VigilFileAtomic -Path $kept -Text ([System.IO.File]::ReadAllText($cand)) }
        $parsed = ConvertFrom-VigilConfig -Path $kept
        $records = Test-VigilConfig -Parsed $parsed
        # Where configuration comes from, and where state is kept, are
        # decided on the host (6.8).
        if ($csrc) {
            foreach ($e in $parsed.Entries) {
                if ($e.Section -ceq 'vigil' -and @('config_source', 'config_file', 'state_dir') -ccontains $e.Key) {
                    $records.Add([pscustomobject]@{ Kind = 'ERROR'; Job = ''; Line = $e.Line; Code = 'E_NOT_FROM_SOURCE'
                            Message = "'$($e.Key)' cannot be set by a fetched configuration; it is set on the host" })
                }
            }
        }
        if ($parsed.Errors.Count -gt 0 -or @($records | Where-Object { $_.Kind -ceq 'ERROR' }).Count -gt 0) {
            foreach ($l in (Format-VigilConfigReport -Parsed $parsed -Records $records).Split("`n")) { if ($l) { & $note "  $l" } }
            if ($csrc) { & $failed $csrc "$cfile has errors" } else { $f.Failed = 'the configuration has errors' }
        }
    }

    if (-not $f.Failed) {
        # Every valid job's script, disabled jobs included (16.5), once each.
        $refs = New-Object 'System.Collections.Generic.List[object]'
        foreach ($sec in $parsed.Sections) {
            if (-not $sec.Name.StartsWith('job.', [System.StringComparison]::Ordinal)) { continue }
            $id = $sec.Name.Substring(4)
            if (@($records | Where-Object { $_.Kind -ceq 'INVALID' -and $_.Job -ceq $id }).Count -gt 0) { continue }
            $src = Get-VigilConfigValue $parsed $sec.Name 'source' ''
            if (-not $src) { continue }
            $file = Get-VigilConfigValue $parsed $sec.Name 'file' ''
            $want = (Get-VigilConfigValue $parsed $sec.Name 'sha256' '').ToLowerInvariant()
            if (@($refs | Where-Object { $_.Src -ceq $src -and $_.File -ceq $file -and $_.Want -ceq $want }).Count -gt 0) { continue }
            $refs.Add(@{ Src = $src; File = $file; Want = $want })
        }
        $lines = "config $sha`n"
        foreach ($x in $refs) {
            $r = & $ref $parsed $x.Src $x.File $x.Want
            if ($r.Why) { & $failed $x.Src $r.Why; continue }
            $body += "script         = $($x.Src) $($r.Entry) $($r.Sha) $($x.File)`n"
            $lines += "script $($x.Src) $($x.File) $($r.Sha)`n"
        }
        # A source no job uses any more is still checked for the next
        # candidate.
        foreach ($sec in $parsed.Sections) {
            if ($sec.Name.StartsWith('source.', [System.StringComparison]::Ordinal)) {
                & $next ($f.Now + (Get-VigilFetchSource $parsed $sec.Name.Substring(7)).Every)
            }
        }
    }

    if (-not $f.Failed) {
        # The revision: the configuration and every script, by digest.
        $revision = (Get-VigilTextSha $lines).Substring(0, 12)
        $body = "[active]`nschema_version = 1`nrevision       = $revision`nconfig         = $sha`norigin         = $origin`n$body"
        $activePath = Join-Path $state 'config.active'
        $old = ''
        if ([System.IO.File]::Exists($activePath)) {
            $old = (@([System.IO.File]::ReadAllLines($activePath) | Where-Object { -not $_.StartsWith('activated_epoch') }) -join "`n") + "`n"
        }
        if ($old -cne $body) {
            if ([System.IO.File]::Exists($activePath)) { [System.IO.File]::Copy($activePath, (Join-Path $state 'config.previous'), $true) }
            Write-VigilFileAtomic -Path $activePath -Text "${body}activated_epoch = $($f.Now)`n"
            & $note "configuration revision $revision activated ($origin)"
            $f.Events.Add("$($f.Now) vigil.config.activated 1 count $($f.Tags) revision=$revision")
        }
        # Sources no longer named are forgotten, with their cache.
        foreach ($p in [System.IO.Directory]::GetFiles((Join-Path $state 'sources'), '*.state')) {
            $name = [System.IO.Path]::GetFileNameWithoutExtension($p)
            if ($name -ceq $csrc -or ($parsed.Sections | Where-Object { $_.Name -ceq "source.$name" })) { continue }
            [System.IO.File]::Delete($p)
            $d = Join-Path $cache $name
            if ([System.IO.Directory]::Exists($d)) { [System.IO.Directory]::Delete($d, $true) }
        }
        Remove-VigilFetchGarbage -Root $Root -State $state
    }

    # When to come back: the earliest next check of any source used.
    if ($null -eq $f.Next) { $f.Next = $f.Now + 300 }
    Write-VigilFileAtomic -Path (Join-Path $state 'fetch.next') -Text "next_epoch = $($f.Next)`nlocal = $local`n"
    if ($f.Events.Count -gt 0) {
        $in = Join-Path $Ctx.Spool 'incoming'
        [void](New-Item -ItemType Directory -Force -Path $in)
        Write-VigilFileAtomic -Path (Join-Path $in "$($f.Now)-vigil_fetch.events") -Text (($f.Events | ForEach-Object { "$_`n" }) -join '')
    }
    if ([System.IO.Directory]::Exists($st)) { [System.IO.Directory]::Delete($st, $true) }
    if ($f.Failed) { return @{ Ok = $false; Reason = $f.Failed } }
    return @{ Ok = $true; Reason = '' }
}

# Removes cache entries named by neither the active nor the previous record
# nor a source's current state, unless a run is in progress (16.5).
function Remove-VigilFetchGarbage {
    param([string]$Root, [string]$State)
    $locks = Join-Path $State 'locks'
    if ([System.IO.Directory]::Exists($locks)) {
        foreach ($l in [System.IO.Directory]::GetFiles($locks)) {
            $n = [System.IO.Path]::GetFileName($l)
            if ($n -cmatch '\.(token|launch)$' -and $n -cnotmatch '^vigil_(fetch|sender)\.') { return }
        }
    }
    $keep = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($p in @((Join-Path $State 'config.active'), (Join-Path $State 'config.previous'))) {
        if (-not [System.IO.File]::Exists($p)) { continue }
        foreach ($l in [System.IO.File]::ReadAllLines($p)) {
            if ($l -cmatch '^config += (.*)$') { [void]$keep.Add("configs\$($Matches[1]).config") }
            elseif ($l -cmatch '^script += (\S+) (\S+) ') { [void]$keep.Add("$($Matches[1])\$($Matches[2])") }
        }
    }
    $sources = Join-Path $State 'sources'
    if ([System.IO.Directory]::Exists($sources)) {
        foreach ($p in [System.IO.Directory]::GetFiles($sources, '*.state')) {
            foreach ($l in [System.IO.File]::ReadAllLines($p)) {
                if ($l -cmatch '^entry += (\S+)$') { [void]$keep.Add("$([System.IO.Path]::GetFileNameWithoutExtension($p))\$($Matches[1])") }
            }
        }
    }
    $cache = Join-Path $Root 'cache'
    if ([System.IO.Directory]::Exists($cache)) {
        foreach ($s in [System.IO.Directory]::GetDirectories($cache)) {
            $name = [System.IO.Path]::GetFileName($s)
            if ($name -ceq 'staging') { continue }
            foreach ($d in [System.IO.Directory]::GetFileSystemEntries($s)) {
                $e = [System.IO.Path]::GetFileName($d)
                if ($e -ceq 'repo.git' -or $keep.Contains("$name\$e")) { continue }
                try { if ([System.IO.Directory]::Exists($d)) { [System.IO.Directory]::Delete($d, $true) } else { [System.IO.File]::Delete($d) } } catch { }
            }
        }
    }
    $configs = Join-Path $State 'configs'
    if ([System.IO.Directory]::Exists($configs)) {
        foreach ($c in [System.IO.Directory]::GetFiles($configs, '*.config')) {
            if (-not $keep.Contains("configs\$([System.IO.Path]::GetFileName($c))")) { try { [System.IO.File]::Delete($c) } catch { } }
        }
    }
}
