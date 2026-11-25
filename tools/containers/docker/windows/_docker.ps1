# _docker.ps1 - what every job of the docker pack shares: where the engine
# is, a GET to it, and the helpers the jobs use. Not a job: each job script
# dot-sources it.
#
# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# Reads the Docker engine's API at DOCKER_HOST: npipe:////./pipe/docker_engine
# by default (Docker's engine on Windows Server, and Docker Desktop). Every
# request is a GET. The account the job runs as must be allowed to use the pipe (an
# administrator, or a member of the group the engine names in daemon.json,
# "group": "docker-users"): that is as good as an administrator on the
# machine, as it is for anyone who can run docker.

$ErrorActionPreference = 'Stop'
$script:Inv = [Globalization.CultureInfo]::InvariantCulture
$script:Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
# How many containers a job names, one by one; the rest are counted.
$script:Most = 100
if ("$env:DOCKER_MOST" -match '^\d+$') { $script:Most = [int]$env:DOCKER_MOST }
$script:Timeout = 60
if ("$env:DOCKER_TIMEOUT" -match '^\d+$') { $script:Timeout = [int]$env:DOCKER_TIMEOUT }

$script:DockerHost = "$env:DOCKER_HOST"
if (-not $script:DockerHost) { $script:DockerHost = 'npipe:////./pipe/docker_engine' }
$script:Pipe = $null
if ($script:DockerHost -match '^npipe:/+\./pipe/(.+)$') { $script:Pipe = $Matches[1] }
else {
    [Console]::Error.WriteLine("${Job}: DOCKER_HOST is $($script:DockerHost): the docker pack reads the engine on this machine, at npipe:////./pipe/<name>")
    exit 1
}

# Get-Answer <path>: @{ State; Body }. State is ok, down (no engine
# answers: a reading), denied (this account may not use the pipe), missing
# (404) or failed (said in Body).
function Get-Answer([string]$Path) {
    $stream = $null
    try {
        try {
            $stream = New-Object System.IO.Pipes.NamedPipeClientStream('.', $script:Pipe, [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
            $stream.Connect(5000)
        } catch [System.UnauthorizedAccessException] {
            return @{ State = 'denied'; Body = '' }
        } catch {
            # No such pipe, nothing listening, or the wait ran out.
            return @{ State = 'down'; Body = '' }
        }
        # HTTP/1.0: the engine answers whole, then closes.
        $ask = [Text.Encoding]::ASCII.GetBytes("GET $Path HTTP/1.0`r`nHost: docker`r`nAccept: application/json`r`n`r`n")
        $stream.Write($ask, 0, $ask.Length)
        $stream.Flush()
        $all = New-Object System.IO.MemoryStream
        $buf = New-Object byte[] 65536
        $until = [DateTime]::UtcNow.AddSeconds($script:Timeout)
        while ($true) {
            $read = $stream.BeginRead($buf, 0, $buf.Length, $null, $null)
            $left = [int]($until - [DateTime]::UtcNow).TotalMilliseconds
            if ($left -le 0 -or -not $read.AsyncWaitHandle.WaitOne($left)) { return @{ State = 'failed'; Body = "no answer to $Path within $($script:Timeout) seconds" } }
            $n = $stream.EndRead($read)
            if ($n -le 0) { break }
            $all.Write($buf, 0, $n)
        }
        $bytes = $all.ToArray()
        # The head ends at the first empty line; it is ASCII, so a byte is a character.
        $latin = [Text.Encoding]::GetEncoding(28591).GetString($bytes)
        $cut = $latin.IndexOf("`r`n`r`n")
        if ($cut -lt 0 -or $latin -notmatch '^HTTP/\d\.\d (\d{3})') { return @{ State = 'failed'; Body = "$($script:DockerHost) answers, but not as a Docker engine" } }
        $code = [int]$Matches[1]
        $head = $latin.Substring(0, $cut)
        $at = $cut + 4
        if ($head -match '(?im)^Transfer-Encoding:\s*chunked') {
            # Each piece: its size in hexadecimal on a line, then that many bytes.
            $whole = New-Object System.IO.MemoryStream
            while ($at -lt $bytes.Length) {
                $eol = $latin.IndexOf("`r`n", $at)
                if ($eol -lt 0) { break }
                $size = [Convert]::ToInt32(($latin.Substring($at, $eol - $at) -split ';')[0].Trim(), 16)
                if ($size -le 0) { break }
                $size = [Math]::Min($size, $bytes.Length - $eol - 2)
                $whole.Write($bytes, $eol + 2, $size)
                $at = $eol + 2 + $size + 2
            }
            $body = [Text.Encoding]::UTF8.GetString($whole.ToArray())
        } else {
            $body = [Text.Encoding]::UTF8.GetString($bytes, $at, $bytes.Length - $at)
        }
        if ($code -eq 200) { return @{ State = 'ok'; Body = $body } }
        if ($code -eq 404) { return @{ State = 'missing'; Body = $body } }
        return @{ State = 'failed'; Body = "$Path answered HTTP $code" }
    } catch {
        return @{ State = 'failed'; Body = "$($script:DockerHost): $($_.Exception.Message)" }
    } finally {
        if ($stream) { $stream.Dispose() }
    }
}

# Read-Json <text>: objects as dictionaries and lists as arrays, of any
# size, on Windows PowerShell 5.1 (whose ConvertFrom-Json stops at 2 MB)
# and on PowerShell 7 alike.
function Read-Json([string]$Text) {
    if ($PSVersionTable.PSVersion.Major -ge 6) { return , (ConvertFrom-Json -InputObject $Text -AsHashtable -Depth 64) }
    Add-Type -AssemblyName System.Web.Extensions
    $reader = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $reader.MaxJsonLength = [int]::MaxValue
    $reader.RecursionLimit = 64
    return , $reader.DeserializeObject($Text)
}

# Get-Json <path>: the answer, read; or the run ends, saying why. With
# -Missing, a 404 is $null (a container removed since the list was read).
function Get-Json([string]$Path, [switch]$Missing) {
    $a = Get-Answer $Path
    switch ($a.State) {
        'ok' { return , (Read-Json $a.Body) }
        'missing' { if ($Missing) { return $null }; [Console]::Error.WriteLine("${Job}: $Path answered HTTP 404"); exit 1 }
        'denied' { [Console]::Error.WriteLine("${Job}: this account may not use $($script:DockerHost): run the job as an administrator, or as a member of the group daemon.json names (`"group`": `"docker-users`")"); exit 1 }
        'down' { [Console]::Error.WriteLine("${Job}: the engine stopped answering at $Path"); exit 1 }
        default { [Console]::Error.WriteLine("${Job}: $($a.Body)"); exit 1 }
    }
}

# Test-Engine: the engine's version in $script:Version, and "metric up". Nothing answering is
# a reading: up 0, and the run succeeds.
function Test-Engine {
    $a = Get-Answer '/version'
    if ($a.State -eq 'down') { 'metric up 0'; exit 0 }
    if ($a.State -eq 'denied') {
        'metric up 0'
        [Console]::Error.WriteLine("${Job}: this account may not use $($script:DockerHost): run the job as an administrator, or as a member of the group daemon.json names (`"group`": `"docker-users`")")
        exit 1
    }
    $v = $null
    if ($a.State -eq 'ok') { try { $v = Read-Json $a.Body } catch { $v = $null } }
    if ($null -eq $v -or -not $v.ApiVersion) {
        'metric up 0'
        [Console]::Error.WriteLine("${Job}: $(if ($a.State -eq 'ok') { "$($script:DockerHost) answers, but not as a Docker engine" } else { $a.Body })")
        exit 1
    }
    $script:Version = $v
    'metric up 1'
}

# Safe <text>: a tag's value: no spaces, never empty, at most 120
# characters.
function Safe($Text) {
    $s = [regex]::Replace("$Text", '[^A-Za-z0-9@._:/+-]', '_')
    if ($s -eq '') { return 'none' }
    if ($s.Length -gt 120) { return $s.Substring(0, 120) }
    return $s
}

# Num <number>: whole when it is whole, else at most three decimals, and
# never an exponent.
function Num($Value) {
    if ($null -eq $Value) { return '0' }
    $d = [double]$Value
    if ($d -eq [Math]::Floor($d)) { return $d.ToString('0', $script:Inv) }
    $r = [Math]::Round($d * 1000, [MidpointRounding]::AwayFromZero) / 1000
    return $r.ToString('0.###', $script:Inv)
}

# N <value>: a number, 0 when there is none.
function N($Value) { if ($null -eq $Value) { return [double]0 }; return [double]$Value }

# Name-Of <container>: its name, without the slash the engine puts first.
function Name-Of($C) {
    $n = $null
    if ($C.Names) { $n = @($C.Names)[0] } elseif ($C.Name) { $n = $C.Name } elseif ($C.name) { $n = $C.name } else { $n = $C.Id }
    return ("$n" -replace '^/', '')
}

# Epoch <time>: seconds since 1970, or 0 where the engine has none.
function Epoch($Time) {
    $t = "$Time"
    if (-not $t -or $t.StartsWith('0001-')) { return 0 }
    $t = [regex]::Replace($t, '\.\d+', '')
    $d = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($t, $script:Inv, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$d)) { return $d.ToUnixTimeSeconds() }
    return 0
}

# By-Name <containers>: in the order the Linux scripts print them (by
# name, byte by byte).
function By-Name($List) {
    $items = [object[]]@($List | Where-Object { $null -ne $_ })
    $keys = [string[]]@($items | ForEach-Object { Name-Of $_ })
    if ($items.Length -gt 1) { [Array]::Sort($keys, $items, [StringComparer]::Ordinal) }
    return , $items
}
