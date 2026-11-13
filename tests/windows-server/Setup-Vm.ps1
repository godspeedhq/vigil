#Requires -Version 5.1
#Requires -RunAsAdministrator

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
    Makes a Windows Server test VM reachable over SSH as vigil-test, by key
    only (backlog 26).
.DESCRIPTION
    For a test VM on a Hyper-V internal or private switch, snapshotted
    first. Run once, as an administrator, on the VM itself:

        .\Setup-Vm.ps1 -PublicKey 'ssh-ed25519 AAAA... vigil-test'
        .\Setup-Vm.ps1 -PublicKey '...' -Administrator

    - Creates the local account vigil-test, with a long random password that
      is never shown or stored: the key is the only way in. -Administrator
      adds it to Administrators, for the system-mode tests (service install
      needs it); without it, only user mode can be tested.
    - Installs and starts the OpenSSH server: the built-in capability on
      Server 2019 and later. Server 2016 has none: install Win32-OpenSSH
      (github.com/PowerShell/Win32-OpenSSH, the MSI) first, then run this.
    - Puts the key where sshd reads it for vigil-test, readable by nobody
      else, adds vigil-test to OpenSSH Users where that group exists (Server
      2025 lets in no one else), and opens port 22 to the local subnet only,
      on every network profile.
    - Prints the VM's addresses.

    Run again with the same key, it changes nothing. -Remove undoes it all
    except the OpenSSH server itself.
#>
param(
    [string]$PublicKey,
    [switch]$Administrator,
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$user = 'vigil-test'
$keys = Join-Path $env:ProgramData 'ssh\vigil-test_authorized_keys'
$config = Join-Path $env:ProgramData 'ssh\sshd_config'
$rule = 'Vigil test SSH'
$match = "Match User $user`r`n    AuthorizedKeysFile __PROGRAMDATA__/ssh/vigil-test_authorized_keys"

function Say { param([string]$Text) Write-Host "setup-vm: $Text" }

if ($Remove) {
    if (Get-LocalUser -Name $user -ErrorAction SilentlyContinue) { Remove-LocalUser -Name $user; Say "removed the account $user" }
    if (Test-Path -LiteralPath $keys) { Remove-Item -LiteralPath $keys -Force; Say "removed $keys" }
    if ((Test-Path -LiteralPath $config) -and ([IO.File]::ReadAllText($config)).Contains($match)) {
        $text = ([IO.File]::ReadAllText($config)).Replace("$match`r`n`r`n", '').Replace("`r`n`r`n$match`r`n", "`r`n")
        [IO.File]::WriteAllText($config, $text)
        Restart-Service sshd
        Say "removed $user's block from sshd_config"
    }
    Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    Say 'done; the OpenSSH server is left installed'
    return
}

if ($PublicKey -notmatch '^(ssh-ed25519|ecdsa-sha2-nistp\d+|ssh-rsa) [A-Za-z0-9+/=]+( .*)?$') {
    throw 'give -PublicKey the one line of a public key (ssh-ed25519 AAAA...)'
}

# The OpenSSH server.
if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
    $cap = $null
    if (Get-Command Get-WindowsCapability -ErrorAction SilentlyContinue) {
        $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if (-not $cap) {
        throw 'no OpenSSH server here, and Windows offers none (Server 2016): install the Win32-OpenSSH MSI from github.com/PowerShell/Win32-OpenSSH/releases, then run this again'
    }
    Say "installing $($cap.Name)"
    [void](Add-WindowsCapability -Online -Name $cap.Name)
}
Set-Service sshd -StartupType Automatic
Start-Service sshd
Say 'the OpenSSH server is running, and starts at boot'

# The account: a random password nobody sees.
if (-not (Get-LocalUser -Name $user -ErrorAction SilentlyContinue)) {
    $bytes = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $pw = ConvertTo-SecureString ('Vt1!' + [Convert]::ToBase64String($bytes)) -AsPlainText -Force
    [void](New-LocalUser -Name $user -Password $pw -PasswordNeverExpires -UserMayNotChangePassword -Description 'Vigil tests, SSH key only')
    Say "created the account $user"
}
$admins = Get-LocalGroup -SID 'S-1-5-32-544'
$isAdmin = [bool](Get-LocalGroupMember -Group $admins -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*\$user" })
if ($Administrator -and -not $isAdmin) { Add-LocalGroupMember -Group $admins -Member $user; Say "$user is now an administrator" }
if (-not $Administrator -and $isAdmin) { Remove-LocalGroupMember -Group $admins -Member $user; Say "$user is no longer an administrator" }
# Server 2025's built-in OpenSSH lets in only administrators and the members
# of "OpenSSH Users" (AllowGroups in its sshd_config): without this, the key
# is refused (49). Earlier versions have no such group.
if (Get-LocalGroup -Name 'OpenSSH Users' -ErrorAction SilentlyContinue) {
    if (-not (Get-LocalGroupMember -Group 'OpenSSH Users' -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*\$user" })) {
        Add-LocalGroupMember -Group 'OpenSSH Users' -Member $user
    }
    Say "$user is in the OpenSSH Users group"
}

# The key, in a file of its own that only SYSTEM, Administrators and
# vigil-test can read: sshd refuses a key file others could change.
[IO.File]::WriteAllText($keys, "$PublicKey`n")
$acl = New-Object Security.AccessControl.FileSecurity
$acl.SetAccessRuleProtection($true, $false)
foreach ($who in @('NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators')) {
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($who, 'FullControl', 'Allow')))
}
$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($user, 'Read', 'Allow')))
Set-Acl -LiteralPath $keys -AclObject $acl
# A Match block for vigil-test alone, before any other: sshd takes the first
# value it finds, and Windows' own "Match Group administrators" block would
# otherwise send an administrator to administrators_authorized_keys.
$text = [IO.File]::ReadAllText($config)
if (-not $text.Contains($match)) {
    $at = [regex]::Match($text, '(?m)^Match ')
    if ($at.Success) { $text = $text.Insert($at.Index, "$match`r`n`r`n") }
    else { $text = $text.TrimEnd() + "`r`n`r`n$match`r`n" }
    [IO.File]::WriteAllText($config, $text)
    Restart-Service sshd
}
Say "the key is in $keys"

# Port 22, from the local subnet only, on every network profile: Hyper-V's
# Default Switch network is Public, where Windows' own sshd rule (Private
# only, on Server 2025) does not apply (49).
if (-not (Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue)) {
    [void](New-NetFirewallRule -DisplayName $rule -Direction Inbound -Protocol TCP -LocalPort 22 -RemoteAddress LocalSubnet -Profile Any -Action Allow)
}
Say 'port 22 is open to the local subnet only'

$ips = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } | ForEach-Object { $_.IPAddress })
Say "addresses: $($ips -join ', ')"
Say "from the laptop: ssh -J vigil-test@<test machine> $user@$($ips | Select-Object -First 1)"
