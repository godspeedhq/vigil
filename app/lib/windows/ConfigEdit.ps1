# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# ConfigEdit.ps1 - vigil config: edit the configuration as crontab -e does
# (SPECIFICATION.md 16.6).
#
#   Invoke-VigilConfigEdit -Root
#
# Opens a copy of config\vigil.config in %VISUAL%, %EDITOR% or Notepad,
# checks the copy with the supervisor's own parser and validation, and puts
# it in place of the configuration only when nothing in it is ERROR or
# INVALID. At a console a rejected copy can be edited again. The supervisor
# picks the file up at its next tick (16.1). Returns 0 when saved or
# unchanged, 1 when nothing was saved; writes its own output.
#
# Requires Config.ps1, Validate.ps1, Worker.ps1 and Precheck.ps1.

function Invoke-VigilConfigEdit {
    param([string]$Root)
    $err = { param($m) [Console]::Error.WriteLine("vigil: $m") }
    $cfg = Join-Path $Root 'config\vigil.config'
    if (-not [System.IO.File]::Exists($cfg)) { & $err "no configuration at ${cfg}: vigil init writes one"; return 1 }
    # A pointer file only says where the configuration is (6.8): edit it there.
    # One that is broken is still opened here, to be fixed.
    try { $source = [string](Get-VigilConfigValue (ConvertFrom-VigilConfig -Path $cfg) 'vigil' 'config_source' '') } catch { $source = '' }
    if ($source) {
        & $err "this host's configuration comes from $source (config_source in $cfg): change it there; edit this file with any editor only to change where it comes from"
        return 1
    }
    $dir = Split-Path -Parent $cfg
    # Opened for writing and closed at once, changing nothing: the only test of
    # access that ACLs cannot fool.
    try { ([System.IO.File]::Open($cfg, 'Open', 'ReadWrite', 'ReadWrite')).Dispose() }
    catch {
        & $err "cannot write ${cfg}: run it as the configuration's owner (an elevated prompt for a system install)"
        return 1
    }

    # Beside the configuration, so the save stays on one volume.
    $work = Join-Path $dir ('.vigil-config.' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    try { [void](New-Item -ItemType Directory -Path $work -ErrorAction Stop) }
    catch { & $err "cannot make a folder in $dir"; return 1 }
    try {
        $copy = Join-Path $work 'vigil.config'
        [System.IO.File]::Copy($cfg, $copy)
        $orig = [System.IO.File]::ReadAllBytes($cfg)
        $same = { param([byte[]]$a, [byte[]]$b) [Convert]::ToBase64String($a) -ceq [Convert]::ToBase64String($b) }

        $editor = if ($env:VISUAL) { $env:VISUAL } elseif ($env:EDITOR) { $env:EDITOR } else { '' }
        while ($true) {
            # The editor setting is a command line, so cmd runs it as typed and an
            # editor with arguments works (code --wait). A setting that is the path
            # of a file, as C:\Program Files\... often is, is quoted whole. Notepad
            # needs no shell.
            if ($editor) {
                $line = if ([System.IO.File]::Exists($editor)) { "`"$editor`"" } else { $editor }
                $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -ArgumentList "/d /s /c `"$line `"$copy`"`"" -NoNewWindow -Wait -PassThru
                $shown = $editor
            }
            else {
                $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\notepad.exe') -ArgumentList "`"$copy`"" -Wait -PassThru
                $shown = 'notepad'
            }
            if ($p.ExitCode -ne 0) { & $err "the editor ($shown) exited with $($p.ExitCode); nothing was changed"; return 1 }
            $now = [System.IO.File]::ReadAllBytes($copy)
            if (& $same $now $orig) { [Console]::Out.WriteLine('no changes'); return 0 }
            $parsed = ConvertFrom-VigilConfig -Path $copy
            $records = @(Test-VigilConfig -Parsed $parsed)
            # A broken job would stop running unnoticed, so it is refused here even
            # though the supervisor would only skip it.
            $refused = $parsed.Errors.Count -gt 0 -or @($records | Where-Object { $_.Kind -ceq 'ERROR' -or $_.Kind -ceq 'INVALID' }).Count -gt 0
            if (-not $refused) { break }
            [Console]::Out.WriteLine('The configuration has problems and was not saved:')
            foreach ($l in (Format-VigilConfigReport -Parsed $parsed -Records $records).TrimEnd("`n").Split("`n")) { [Console]::Out.WriteLine("  $l") }
            if ([Console]::IsInputRedirected) { [Console]::Out.WriteLine('nothing was changed'); return 1 }
            $a = Read-Host -Prompt 'Edit again? [Y/n]'
            if ($a -and $a -notmatch '^[Yy]') { [Console]::Out.WriteLine('nothing was changed'); return 1 }
        }

        # Warnings do not stop the save, but are worth seeing.
        if ($records.Count -gt 0) {
            foreach ($l in (Format-VigilConfigReport -Parsed $parsed -Records $records).TrimEnd("`n").Split("`n")) { [Console]::Out.WriteLine("  $l") }
        }
        if (-not (& $same ([System.IO.File]::ReadAllBytes($cfg)) $orig)) {
            try {
                [System.IO.File]::Copy($copy, "$cfg.edited", $true)
                & $err "$cfg changed while it was being edited, so it was left as it is; your version is in $cfg.edited"
            }
            catch { & $err "$cfg changed while it was being edited, so it was left as it is" }
            return 1
        }
        # Replace keeps the configuration's own ACL. Retried for a moment: the
        # supervisor holds the file open briefly while it reads it.
        for ($try = 1; ; $try++) {
            try { [System.IO.File]::Replace($copy, $cfg, [System.Management.Automation.Language.NullString]::Value); break }
            catch [System.IO.IOException] {
                if ($try -ge 50) { & $err "cannot save ${cfg}; nothing was changed"; return 1 }
                Start-Sleep -Milliseconds 100
            }
        }
        [Console]::Out.WriteLine("saved ${cfg}: the supervisor uses it from its next tick")
        return 0
    }
    finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
