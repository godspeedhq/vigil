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
    Vigil secrets - Windows PowerShell 5.1 compatible.
.DESCRIPTION
    Resolves secret references (SPECIFICATION.md 6.5) when a run starts, and
    manages Vigil's own secret store. The twin of secrets.sh.

    Resolve-VigilSecret -Root <dir> -Parsed <config> -Reference <ref>
        returns @{ Ok; Value; Why }. Why never contains the value.
    Set-VigilSecret / Remove-VigilSecret / Get-VigilSecretList -Root <dir>

    The store is config\secrets\<NAME>, one file per secret. On a user
    install it holds the value encrypted with DPAPI for the account Vigil
    runs as (ConvertFrom-SecureString), with an owner-only ACL: only that
    account on this machine can decrypt it. On a system install, whose
    service runs as LocalSystem, which nobody signs in as, it is set from an
    elevated prompt, encrypted with DPAPI for the machine ("machine:" and
    base64), and the folder is SYSTEM's and Administrators' only, as the
    root is (42). env: references are read from the registry
    (user scope, then machine scope) when they are resolved, so a changed
    variable needs no restart; the inherited environment is the fallback.
#>

$Script:VigilSecretName = '^[A-Za-z_][A-Za-z0-9_]*$'

function Get-VigilSecretDir {
    param([string]$Root)
    return Join-Path $Root 'config\secrets'
}

# A store this account may not read is not empty, nor a secret in it
# missing: each store is its own account's (45).
function Get-VigilSecretDeniedMessage {
    param([string]$Denied)
    return "cannot read $Denied from this account: secrets are set and read as the account Vigil runs as (an elevated prompt for a system install)"
}

# A system install's root, as service install --system leaves it (17): no
# inherited access, and full control for SYSTEM and Administrators only. Its
# secrets are the machine's (42).
$Script:VigilSystemSids = @('S-1-5-18', 'S-1-5-32-544')
function Test-VigilSystemRoot {
    param([string]$Root)
    try { $acl = Get-Acl -LiteralPath $Root -ErrorAction Stop } catch { return $false }
    if (-not $acl.AreAccessRulesProtected) { return $false }
    $sids = @($acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]) |
            ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique)
    return (($sids -join ',') -ceq ($Script:VigilSystemSids -join ','))
}

# DPAPI for the machine: any process here may decrypt it, so the folder's
# ACL is what protects it, as a 0600 file's mode does on Linux.
function Initialize-VigilProtectedData {
    if (-not ('System.Security.Cryptography.ProtectedData' -as [type])) { Add-Type -AssemblyName System.Security }
}

# Windows refuses its data protection (DPAPI), which the store uses, to a
# logon that has no password: an SSH key, a scheduled task without a stored
# password. Whether this logon is one, found by asking DPAPI for something
# small: refused with "Access is denied" (0x80070005). A secret this logon
# cannot read says only "key not valid", as one of another account does, so
# the error alone cannot tell them apart (48). VIGIL_TEST_DPAPI_REFUSED
# stands for such a logon in the tests (22.4.5).
$Script:VigilDpapiRefusedMessage = "Windows refuses its data protection to this logon, which has no password (an SSH key, or a task without a stored password): set and check secrets from a console or remote desktop session as this account, or use env: or store:"
function Test-VigilDpapiRefused {
    if ($env:VIGIL_TEST_DPAPI_REFUSED) { return $true }
    try {
        [void](ConvertFrom-SecureString -SecureString (ConvertTo-SecureString 'x' -AsPlainText -Force) -ErrorAction Stop)
        return $false
    }
    catch {
        $e = $_.Exception
        while ($e.InnerException) { $e = $e.InnerException }
        return ($e -is [System.Security.Cryptography.CryptographicException]) -and $e.HResult -eq [int]0x80070005
    }
}

# Strips one trailing newline (LF or CRLF).
function Remove-VigilTrailingNewline {
    param([string]$Value)
    if ($Value.EndsWith("`n")) { $Value = $Value.Substring(0, $Value.Length - 1) }
    if ($Value.EndsWith("`r")) { $Value = $Value.Substring(0, $Value.Length - 1) }
    return $Value
}

# An environment variable as a new logon would see it: user scope, then
# machine scope, read from the registry now; else the inherited value. An
# empty registry value is unset, as it is for a new logon.
function Get-VigilFreshEnv {
    param([string]$Name)
    foreach ($scope in @('User', 'Machine')) {
        $v = [Environment]::GetEnvironmentVariable($Name, $scope)
        if ($v) { return $v }
    }
    return [Environment]::GetEnvironmentVariable($Name, 'Process')
}

function Set-VigilSecret {
    param([string]$Root, [string]$Name, [System.Security.SecureString]$Value)
    if ($Name -cnotmatch $Script:VigilSecretName) { throw "not a valid secret name: $Name" }
    $dir = Get-VigilSecretDir $Root
    # Before anything is written: a store this account may not read looks
    # absent, and creating it fails with raw errors (49).
    $denied = Get-VigilDenied $dir
    if ($denied) { throw (Get-VigilSecretDeniedMessage $denied) }
    $system = Test-VigilSystemRoot $Root
    if (-not [System.IO.Directory]::Exists($dir)) { [void](New-Item -ItemType Directory -Force -Path $dir) }
    # Set in full every time: no inherited access and no other entries (an
    # elevated token adds Administrators and SYSTEM by default), only full
    # control, inherited by the files, for this account, or on a system
    # install for SYSTEM and Administrators.
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $who = if ($system) { @($Script:VigilSystemSids | ForEach-Object { New-Object Security.Principal.SecurityIdentifier($_) }) }
    else { @([Security.Principal.WindowsIdentity]::GetCurrent().User) }
    foreach ($sid in $who) {
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $sid, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
    }
    # Only the access entries are written. Set-Acl would try the audit ones
    # too, which needs a privilege an ordinary token lacks: once the folder
    # existed, every later set printed that error (48). Windows PowerShell's
    # .NET has the method on DirectoryInfo; PowerShell 7's, as an extension.
    $info = New-Object System.IO.DirectoryInfo $dir
    if ($info.PSObject.Methods['SetAccessControl']) { $info.SetAccessControl($acl) }
    else { [System.IO.FileSystemAclExtensions]::SetAccessControl($info, $acl) }
    if ($system) {
        # DPAPI for this machine, so the service can read it (42).
        Initialize-VigilProtectedData
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
        try { $bytes = [System.Text.Encoding]::UTF8.GetBytes([System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        try { $text = 'machine:' + [Convert]::ToBase64String([System.Security.Cryptography.ProtectedData]::Protect($bytes, $null, 'LocalMachine')) }
        finally { [Array]::Clear($bytes, 0, $bytes.Length) }
    }
    else {
        # DPAPI, tied to this account on this machine.
        if ($env:VIGIL_TEST_DPAPI_REFUSED) { throw $Script:VigilDpapiRefusedMessage }
        try { $text = ConvertFrom-SecureString -SecureString $Value -ErrorAction Stop }
        catch {
            if (Test-VigilDpapiRefused) { throw $Script:VigilDpapiRefusedMessage }
            throw
        }
    }
    $tmp = Join-Path $dir ".$Name.tmp.$PID"
    [System.IO.File]::WriteAllText($tmp, $text)
    $path = Join-Path $dir $Name
    if ([System.IO.File]::Exists($path)) { [System.IO.File]::Replace($tmp, $path, [System.Management.Automation.Language.NullString]::Value) }
    else { [System.IO.File]::Move($tmp, $path) }
}

function Remove-VigilSecret {
    param([string]$Root, [string]$Name)
    $path = Join-Path (Get-VigilSecretDir $Root) $Name
    $denied = Get-VigilDenied $path
    if ($denied) { throw (Get-VigilSecretDeniedMessage $denied) }
    if (-not [System.IO.File]::Exists($path)) { throw "no secret $Name" }
    [System.IO.File]::Delete($path)
}

function Get-VigilSecretList {
    param([string]$Root)
    $dir = Get-VigilSecretDir $Root
    $denied = Get-VigilDenied $dir
    if ($denied) { throw (Get-VigilSecretDeniedMessage $denied) }
    if (-not [System.IO.Directory]::Exists($dir)) { return }
    $files = [System.IO.Directory]::GetFiles($dir)
    [Array]::Sort($files, [System.StringComparer]::Ordinal)
    foreach ($f in $files) {
        $name = [System.IO.Path]::GetFileName($f)
        if ($name -cnotmatch $Script:VigilSecretName) { continue }
        $when = [System.IO.File]::GetLastWriteTimeUtc($f).ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
        '{0,-32} changed {1}' -f $name, $when
    }
}

function Read-VigilStoredSecret {
    param([string]$Root, [string]$Name)
    $path = Join-Path (Get-VigilSecretDir $Root) $Name
    $denied = Get-VigilDenied $path
    if ($denied) { return @{ Ok = $false; Why = (Get-VigilSecretDeniedMessage $denied) } }
    if (-not [System.IO.File]::Exists($path)) {
        return @{ Ok = $false; Why = "not found in Vigil's secret store (vigil secret set $Name)" }
    }
    $text = [System.IO.File]::ReadAllText($path).Trim()
    if ($text.StartsWith('machine:', [System.StringComparison]::Ordinal)) {
        # A system install's: DPAPI for the machine (42).
        try {
            Initialize-VigilProtectedData
            $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($text.Substring(8)), $null, 'LocalMachine')
            try { return @{ Ok = $true; Value = [System.Text.Encoding]::UTF8.GetString($bytes) } }
            finally { [Array]::Clear($bytes, 0, $bytes.Length) }
        }
        catch { return @{ Ok = $false; Why = 'cannot be decrypted on this machine; set it again with vigil secret set from an elevated prompt' } }
    }
    try {
        if ($env:VIGIL_TEST_DPAPI_REFUSED) { throw 'refused' }
        $secure = ConvertTo-SecureString -String $text -ErrorAction Stop
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { $value = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        return @{ Ok = $true; Value = $value }
    }
    catch {
        if (Test-VigilDpapiRefused) { return @{ Ok = $false; Why = $Script:VigilDpapiRefusedMessage } }
        # Set by another account, or copied from another machine; on a system
        # install, set before 42, for the account that set it.
        return @{ Ok = $false; Why = 'cannot be decrypted by this account on this machine; set it again with vigil secret set as the service account (an elevated prompt for a system install)' }
    }
}

# A helper store: <command> <arg>... get <NAME>, never through a shell,
# within the store's timeout. Its stdout is the value.
function Invoke-VigilSecretHelper {
    param([string]$Root, $Parsed, [string]$Store, [string]$Name)
    $cmd = Get-VigilConfigValue $Parsed "secret_store.$Store" 'command' ''
    if (-not [System.IO.Path]::IsPathRooted($cmd) -and ($cmd.Contains('\') -or $cmd.Contains('/'))) { $cmd = Join-Path $Root $cmd }
    $timeout = Get-VigilConfigValue $Parsed "secret_store.$Store" 'timeout' '10s'
    $seconds = ConvertTo-VigilSeconds $timeout
    $argv = @(foreach ($e in $Parsed.Entries) { if ($e.Section -ceq "secret_store.$Store" -and $e.Key -ceq 'arg') { $e.Value } }) + @('get', $Name)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $cmd
    $psi.Arguments = ($argv | ForEach-Object { ConvertTo-VigilQuotedArg -Arg $_ -Always $false }) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    try { [void]$p.Start() }
    catch { return @{ Ok = $false; Why = 'the helper could not be started' } }
    $p.StandardInput.Close()
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($seconds * 1000)) {
        try { Stop-VigilProcessTree $p.Id } catch { }
        return @{ Ok = $false; Why = "the helper was stopped after ${seconds}s" }
    }
    $p.WaitForExit()
    [void]$errTask.Result
    if ($p.ExitCode -ne 0) { return @{ Ok = $false; Why = "the helper failed (exit code $($p.ExitCode))" } }
    return @{ Ok = $true; Value = (Remove-VigilTrailingNewline $outTask.Result) }
}

function Resolve-VigilSecret {
    param([string]$Root, $Parsed, [string]$Reference)
    if ($Reference.StartsWith('env:', [System.StringComparison]::Ordinal)) {
        $v = Get-VigilFreshEnv $Reference.Substring(4)
        if ($null -eq $v) { return @{ Ok = $false; Why = 'not set in the environment' } }
        return @{ Ok = $true; Value = $v }
    }
    if ($Reference.StartsWith('secret:', [System.StringComparison]::Ordinal)) {
        return Read-VigilStoredSecret $Root $Reference.Substring(7)
    }
    if ($Reference.StartsWith('store:', [System.StringComparison]::Ordinal)) {
        $rest = $Reference.Substring(6)
        $slash = $rest.IndexOf('/')
        $store = $rest.Substring(0, $slash)
        $name = $rest.Substring($slash + 1)
        if (-not ($Parsed.Sections | Where-Object { $_.Name -ceq "secret_store.$store" })) {
            return @{ Ok = $false; Why = "no [secret_store.$store] section" }
        }
        $type = Get-VigilConfigValue $Parsed "secret_store.$store" 'type' ''
        if ($type -ceq 'helper') { return Invoke-VigilSecretHelper $Root $Parsed $store $name }
        if (@('hashicorp_vault', 'azure_keyvault', 'aws_secrets_manager', 'gcp_secret_manager') -ccontains $type) {
            return Get-VigilStoreSecret -Root $Root -Parsed $Parsed -Store $store -Type $type -Name $name
        }
        return @{ Ok = $false; Why = "store type $type not implemented yet" }
    }
    return @{ Ok = $false; Why = 'not a secret reference' }
}
