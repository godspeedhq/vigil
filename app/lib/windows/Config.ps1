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
    Vigil configuration parser - Windows PowerShell 5.1 compatible.
.DESCRIPTION
    Parses the Vigil INI dialect (SPECIFICATION.md 6.1). Must produce exactly
    the same result as config.sh - tests/conformance/parser holds the shared
    cases.

    The parser is deliberately dumb: it records every "key = value" in file
    order, repeated keys included, and leaves meaning (allowed keys, duplicate
    keys, value types) to validation.

    Rules enforced here:
      - A trailing CR is stripped (CRLF files are accepted); a UTF-8 BOM at
        the start of the file is stripped.
      - Only TAB and printable ASCII (space to ~) are allowed - E_INVALID_CHAR.
      - Leading and trailing spaces/tabs are trimmed from lines, keys, values.
      - Blank lines and lines starting with # or ; are ignored.
      - [name] or [name.name], lowercase a-z 0-9 _ only - E_SECTION_SYNTAX.
        A repeated header is E_SECTION_DUPLICATE. Keys after a bad or repeated
        header are skipped until the next good header.
      - key = value, split on the first "=". Keys are lowercase a-z 0-9 _,
        optionally starting with "." (for [runners]) - E_KEY_SYNTAX.
      - A key before any section is E_KEY_OUTSIDE_SECTION; a line that is
        none of the above is E_NO_EQUALS.

    PS 5.1 notes:
      - Regex matching uses -cmatch: -match is case-insensitive and would
        accept uppercase keys that bash rejects.
      - The file is decoded as Latin-1 so every byte is exactly one char,
        which makes the character check identical to bash's C-locale check.
      - Functions that return a value contain no Write-Output calls.
#>

$Script:VigilConfigMaxBytes = 1048576

# What stops this account telling whether $Path is there: $Path itself (a
# file it may not read, a folder it may not list), or the nearest folder
# above it that exists and that it may not list; '' when $Path can be read or
# is plainly absent. A system install's root is closed to all but SYSTEM and
# Administrators, and .NET then says what is inside does not exist (45).
function Get-VigilDenied {
    param([string]$Path)
    # Only a refusal counts: a file busy in another process is not this
    # account's problem, and its reader reports it.
    try {
        if ([System.IO.Directory]::Exists($Path)) { [void][System.IO.Directory]::GetFileSystemEntries($Path); return '' }
        if ([System.IO.File]::Exists($Path)) { [System.IO.File]::OpenRead($Path).Dispose(); return '' }
    }
    catch [System.UnauthorizedAccessException] { return $Path }
    catch { return '' }
    $p = [System.IO.Path]::GetDirectoryName($Path)
    while ($p) {
        if ([System.IO.Directory]::Exists($p)) {
            try { [void][System.IO.Directory]::GetFileSystemEntries($p); return '' }
            catch [System.UnauthorizedAccessException] { return $p }
            catch { return '' }
        }
        $p = [System.IO.Path]::GetDirectoryName($p)
    }
    return ''
}

# The message for what Get-VigilDenied found.
function Get-VigilDeniedMessage {
    param([string]$Denied)
    return "cannot read $Denied from this account: run this from an elevated prompt for a system install"
}

function ConvertFrom-VigilConfig {
    param([Parameter(Mandatory = $true)][string]$Path)

    $result = [pscustomobject]@{
        Entries  = New-Object 'System.Collections.Generic.List[object]'
        # Accepted section headers, including empty ones, in file order.
        Sections = New-Object 'System.Collections.Generic.List[object]'
        Errors   = New-Object 'System.Collections.Generic.List[object]'
    }

    $addError = {
        param([int]$Line, [string]$Code, [string]$Message)
        $result.Errors.Add([pscustomobject]@{ Line = $Line; Code = $Code; Message = $Message })
    }

    # A configuration in a folder this account may not look into makes
    # Test-Path fail with "Access is denied" instead of answering.
    try { $isFile = Test-Path -LiteralPath $Path -PathType Leaf -ErrorAction Stop }
    catch {
        & $addError 0 'E_FILE_UNREADABLE' "config file not readable: $Path"
        return $result
    }
    if (-not $isFile) {
        & $addError 0 'E_FILE_NOT_FOUND' "config file not found: $Path"
        return $result
    }

    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
    }
    catch {
        & $addError 0 'E_FILE_UNREADABLE' "config file not readable: $Path"
        return $result
    }

    if ($bytes.Length -gt $Script:VigilConfigMaxBytes) {
        & $addError 0 'E_FILE_TOO_LARGE' "config file is $($bytes.Length) bytes; the limit is $($Script:VigilConfigMaxBytes)"
        return $result
    }

    $offset = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $offset = 3
    }
    $text  = [System.Text.Encoding]::GetEncoding(28591).GetString($bytes, $offset, $bytes.Length - $offset)
    $lines = $text.Split("`n")
    # A final newline leaves an empty last element; bash's read loop does not
    # see a line there, so drop it to keep line counts identical.
    $count = $lines.Length
    if ($count -gt 0 -and $lines[$count - 1].Length -eq 0) { $count-- }

    $reSection = '^\[([a-z0-9_]+(\.[a-z0-9_]+)?)\]$'
    $reKey     = '^\.?[a-z0-9_]+$'
    $reInvalid = '[^\t -~]'
    $trimChars = [char[]]@(' ', "`t")

    $seen     = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $section  = ''
    $skipping = $false

    for ($i = 0; $i -lt $count; $i++) {
        $n    = $i + 1
        $line = $lines[$i]
        if ($line.EndsWith("`r")) { $line = $line.Substring(0, $line.Length - 1) }

        if ($line -cmatch $reInvalid) {
            & $addError $n 'E_INVALID_CHAR' 'only printable ASCII and tab are allowed'
            continue
        }

        $line = $line.Trim($trimChars)

        if ($line.Length -eq 0 -or $line.StartsWith('#') -or $line.StartsWith(';')) {
            continue
        }

        if ($line.StartsWith('[')) {
            if ($line -cmatch $reSection) {
                $section = $Matches[1]
                if ($seen.Add($section)) {
                    $skipping = $false
                    $result.Sections.Add([pscustomobject]@{ Name = $section; Line = $n; First = $result.Entries.Count; Count = 0 })
                }
                else {
                    & $addError $n 'E_SECTION_DUPLICATE' "section [$section] appears more than once"
                    $skipping = $true
                }
            }
            else {
                & $addError $n 'E_SECTION_SYNTAX' "invalid section header: $line"
                $skipping = $true
            }
            continue
        }

        $eq = $line.IndexOf('=')
        if ($eq -lt 0) {
            if (-not $skipping) {
                & $addError $n 'E_NO_EQUALS' "expected 'key = value', a [section] or a comment"
            }
            continue
        }

        if ($skipping) { continue }

        $key   = $line.Substring(0, $eq).Trim($trimChars)
        $value = $line.Substring($eq + 1).Trim($trimChars)

        if ($section.Length -eq 0) {
            & $addError $n 'E_KEY_OUTSIDE_SECTION' "key '$key' appears before any [section]"
            continue
        }
        if (-not ($key -cmatch $reKey)) {
            & $addError $n 'E_KEY_SYNTAX' "invalid key: '$key'"
            continue
        }

        $result.Entries.Add([pscustomobject]@{
            Section = $section
            Key     = $key
            Value   = $value
            Line    = $n
        })
        # A section's keys are contiguous, so lookups can scan only its range.
        $result.Sections[$result.Sections.Count - 1].Count++
    }

    return $result
}

# Formats a parse result in the conformance format, one record per line:
#   <section> TAB <key> TAB <value>      for each entry, in file order
#   ERROR TAB <line> TAB <code>          for each error, in file order
function Format-VigilConfigDump {
    param([Parameter(Mandatory = $true)]$Parsed)

    $sb = New-Object System.Text.StringBuilder
    foreach ($e in $Parsed.Entries) {
        [void]$sb.Append("$($e.Section)`t$($e.Key)`t$($e.Value)`n")
    }
    foreach ($e in $Parsed.Errors) {
        [void]$sb.Append("ERROR`t$($e.Line)`t$($e.Code)`n")
    }
    return $sb.ToString()
}
