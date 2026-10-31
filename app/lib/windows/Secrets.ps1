#Requires -Version 5.1

<#
.SYNOPSIS
    Vigil secrets - Windows PowerShell 5.1 compatible.
.DESCRIPTION
    Resolves secret references (SPECIFICATION.md 6.5) when a run starts, and
    manages Vigil's own secret store. The twin of secrets.sh.

    Resolve-VigilSecret -Root <dir> -Parsed <config> -Reference <ref>
        returns @{ Ok; Value; Why }. Why never contains the value.
    Set-VigilSecret / Remove-VigilSecret / Get-VigilSecretList -Root <dir>

    The store is config\secrets\<NAME>, one file per secret, holding the
    value encrypted with DPAPI for the account Vigil runs as
    (ConvertFrom-SecureString), with an owner-only ACL: only that account on
    this machine can decrypt it. env: references are read from the registry
    (user scope, then machine scope) when they are resolved, so a changed
    variable needs no restart; the inherited environment is the fallback.
#>

$Script:VigilSecretName = '^[A-Za-z_][A-Za-z0-9_]*$'

function Get-VigilSecretDir {
    param([string]$Root)
    return Join-Path $Root 'config\secrets'
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
    if (-not [System.IO.Directory]::Exists($dir)) { [void](New-Item -ItemType Directory -Force -Path $dir) }
    # Owner-only, set in full every time: no inherited access and no other
    # entries (an elevated token adds Administrators and SYSTEM by default),
    # only full control for this account, inherited by the files.
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                [Security.Principal.WindowsIdentity]::GetCurrent().User, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
    Set-Acl -LiteralPath $dir -AclObject $acl
    # DPAPI, tied to this account on this machine.
    $text = ConvertFrom-SecureString -SecureString $Value
    $tmp = Join-Path $dir ".$Name.tmp.$PID"
    [System.IO.File]::WriteAllText($tmp, $text)
    $path = Join-Path $dir $Name
    if ([System.IO.File]::Exists($path)) { [System.IO.File]::Replace($tmp, $path, [System.Management.Automation.Language.NullString]::Value) }
    else { [System.IO.File]::Move($tmp, $path) }
}

function Remove-VigilSecret {
    param([string]$Root, [string]$Name)
    $path = Join-Path (Get-VigilSecretDir $Root) $Name
    if (-not [System.IO.File]::Exists($path)) { throw "no secret $Name" }
    [System.IO.File]::Delete($path)
}

function Get-VigilSecretList {
    param([string]$Root)
    $dir = Get-VigilSecretDir $Root
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
    if (-not [System.IO.File]::Exists($path)) {
        return @{ Ok = $false; Why = "not found in Vigil's secret store (vigil secret set $Name)" }
    }
    try {
        $secure = ConvertTo-SecureString -String ([System.IO.File]::ReadAllText($path).Trim())
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { $value = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        return @{ Ok = $true; Value = $value }
    }
    catch {
        # Set by another account, or copied from another machine.
        return @{ Ok = $false; Why = 'cannot be decrypted by this account on this machine; set it again with vigil secret set as the service account' }
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
        try { & taskkill.exe /T /F /PID $p.Id 2>&1 | Out-Null } catch { }
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
        if (@('hashicorp_vault', 'azure_keyvault', 'aws_secrets_manager') -ccontains $type) {
            return Get-VigilStoreSecret -Root $Root -Parsed $Parsed -Store $store -Type $type -Name $name
        }
        return @{ Ok = $false; Why = "store type $type not implemented yet" }
    }
    return @{ Ok = $false; Why = 'not a secret reference' }
}
