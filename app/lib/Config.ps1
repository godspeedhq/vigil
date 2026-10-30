#Requires -Version 5.1

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
$Script:VigilConfigMaxFiles = 256

function New-VigilConfigResult {
    return [pscustomobject]@{
        Entries  = New-Object 'System.Collections.Generic.List[object]'
        # Accepted section headers, including empty ones, in file order.
        Sections = New-Object 'System.Collections.Generic.List[object]'
        Errors   = New-Object 'System.Collections.Generic.List[object]'
        # { Role; Label } per file read.
        Files    = New-Object 'System.Collections.Generic.List[object]'
        # Section name -> index in Sections, across all files.
        SectionIndex = New-Object 'System.Collections.Generic.Dictionary[string,int]' ([System.StringComparer]::Ordinal)
    }
}

# Parses one file as the main configuration file.
function ConvertFrom-VigilConfig {
    param([Parameter(Mandatory = $true)][string]$Path)
    $result = New-VigilConfigResult
    Read-VigilConfigFile -Result $result -Role 'main' -Label '' -Path $Path
    return $result
}

<#
    Parses several files as one configuration (spec 6.8), in the order given.
    Files is a list of @{ Role; Label; Path }: Role is main, dropin or fetched;
    Label names the file in locations and is empty for the main file, whose
    locations are plain line numbers - elsewhere they are "<label>:<line>".
    Each section may be defined once across all files.
#>
function ConvertFrom-VigilConfigFiles {
    param([Parameter(Mandatory = $true)]$Files)
    $result = New-VigilConfigResult
    if ($Files.Count -gt $Script:VigilConfigMaxFiles) {
        $result.Errors.Add([pscustomobject]@{
            Line = 0; Code = 'E_TOO_MANY_FILES'
            Message = "$($Files.Count) configuration files; the limit is $($Script:VigilConfigMaxFiles)"
        })
        return $result
    }
    foreach ($f in $Files) {
        Read-VigilConfigFile -Result $result -Role $f.Role -Label $f.Label -Path $f.Path
    }
    return $result
}

# Appends one file to a parse result.
function Read-VigilConfigFile {
    param($Result, [string]$Role, [string]$Label, [string]$Path)

    $result = $Result
    $fileIndex = $result.Files.Count
    $result.Files.Add([pscustomobject]@{ Role = $Role; Label = $Label })
    # Prefix that turns a line number into a location.
    $loc = if ($Label.Length -gt 0) { "${Label}:" } else { '' }

    # A plain number in the main file, so single-file results are unchanged.
    $locate = {
        param([int]$N)
        if ($loc.Length -gt 0) { return "$loc$N" }
        return $N
    }
    $addError = {
        param([int]$Line, [string]$Code, [string]$Message)
        $result.Errors.Add([pscustomobject]@{ Line = (& $locate $Line); Code = $Code; Message = $Message })
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        & $addError 0 'E_FILE_NOT_FOUND' "config file not found: $Path"
        return
    }

    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
    }
    catch {
        & $addError 0 'E_FILE_UNREADABLE' "config file not readable: $Path"
        return
    }

    if ($bytes.Length -gt $Script:VigilConfigMaxBytes) {
        & $addError 0 'E_FILE_TOO_LARGE' "config file is $($bytes.Length) bytes; the limit is $($Script:VigilConfigMaxBytes)"
        return
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
                $first = 0
                if ($result.SectionIndex.TryGetValue($section, [ref]$first)) {
                    # Repeated in this file or defined by an earlier one.
                    & $addError $n 'E_SECTION_DUPLICATE' "section [$section] appears more than once; first at $($result.Sections[$first].Line)"
                    $skipping = $true
                }
                else {
                    $skipping = $false
                    $result.SectionIndex[$section] = $result.Sections.Count
                    $result.Sections.Add([pscustomobject]@{
                        Name = $section; Line = (& $locate $n); First = $result.Entries.Count; Count = 0; File = $fileIndex
                    })
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
            Line    = (& $locate $n)
        })
        # A section's keys are contiguous, so lookups can scan only its range.
        $result.Sections[$result.Sections.Count - 1].Count++
    }
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
