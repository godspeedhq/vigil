#Requires -Version 5.1

<#
.SYNOPSIS
    processes.ps1 - the busiest programs on Windows
.DESCRIPTION
    Reads every process's CPU time twice, one second apart, and reports the
    10 programs that used the most CPU in that second and the 10 using the
    most memory: often the same ones, reported once. Processes with the same
    name count together (20 svchost processes are one program), and only
    the name is sent: never a process id, which would make a new series
    every restart, or a command line, which can hold a password.

    One call to the kernel (NtQuerySystemInformation) lists every process
    with its CPU time and memory, for any account, without opening any of
    them, so a standard user's Vigil sees the same as the service.

    Metrics:
        cpu_pct       percent of the whole machine's CPU, all cores together,
                      so it adds up with system.cpu.used_pct (tag: name)
        memory_bytes  working set: memory in use, in bytes (tag: name)

    Example output:
      metric cpu_pct 12.5 name=sqlservr
      metric memory_bytes 1462763520 name=sqlservr
      metric cpu_pct 3.0 name=MsMpEng
      metric memory_bytes 214958080 name=MsMpEng

    Reading the results (starting points: tune them to the machine):
      Look at it when system.cpu.used_pct or system.memory.used_pct is high:
      it names what is using the machine. A program whose memory_bytes only
      ever grows may be leaking.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0 on success, 1 if the data cannot be read
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
#>

$ErrorActionPreference = 'Stop'

$top = 10

# NtQuerySystemInformation, built in memory with Reflection.Emit rather than
# Add-Type, which would start the C# compiler on every run.
$asm = [System.Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly((New-Object System.Reflection.AssemblyName 'VigilPackProcesses'), 'Run')
$type = $asm.DefineDynamicModule('VigilPackProcesses').DefineType('VigilPackProcesses', 'Public, Class, Abstract, Sealed')
$call = $type.DefinePInvokeMethod('NtQuerySystemInformation', 'ntdll.dll', 'Public, Static, PinvokeImpl', 'Standard',
    [int], [type[]]@([int], [IntPtr], [int], [int[]]), 'Winapi', 'Unicode')
$call.SetImplementationFlags('PreserveSig')
$ntdll = $type.CreateType()

$SystemProcessInformation = 5
$STATUS_INFO_LENGTH_MISMATCH = [int]0xC0000004 - [long]4294967296

# Where SYSTEM_PROCESS_INFORMATION keeps what is needed, in a 64-bit and a
# 32-bit PowerShell.
$at = if ([IntPtr]::Size -eq 8) {
    @{ User = 40; Kernel = 48; NameLength = 56; NameBuffer = 64; Pid = 80; WorkingSet = 144 }
} else {
    @{ User = 40; Kernel = 48; NameLength = 56; NameBuffer = 60; Pid = 68; WorkingSet = 104 }
}

# Every process: id, name, CPU time (100-nanosecond ticks) and working set.
function Get-ProcessList {
    $size = 1MB
    while ($true) {
        $buffer = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($size)
        try {
            $needed = New-Object int[] 1
            $status = $ntdll::NtQuerySystemInformation($SystemProcessInformation, $buffer, $size, $needed)
            if ($status -eq $STATUS_INFO_LENGTH_MISMATCH) { $size = [Math]::Max($size * 2, $needed[0] + 64KB); continue }
            if ($status -ne 0) { throw ('NtQuerySystemInformation failed: 0x{0:X8}' -f $status) }
            $list = New-Object System.Collections.Generic.List[object]
            $offset = 0
            while ($true) {
                $entry = [IntPtr]($buffer.ToInt64() + $offset)
                $nameLength = [System.Runtime.InteropServices.Marshal]::ReadInt16($entry, $at.NameLength)
                $name = if ($nameLength -gt 0) {
                    [System.Runtime.InteropServices.Marshal]::PtrToStringUni([System.Runtime.InteropServices.Marshal]::ReadIntPtr($entry, $at.NameBuffer), $nameLength / 2)
                } else { '' }
                $list.Add(@(
                        [System.Runtime.InteropServices.Marshal]::ReadIntPtr($entry, $at.Pid).ToInt64(),
                        $name,
                        ([System.Runtime.InteropServices.Marshal]::ReadInt64($entry, $at.User) + [System.Runtime.InteropServices.Marshal]::ReadInt64($entry, $at.Kernel)),
                        [System.Runtime.InteropServices.Marshal]::ReadIntPtr($entry, $at.WorkingSet).ToInt64()))
                $next = [System.Runtime.InteropServices.Marshal]::ReadInt32($entry, 0)
                if ($next -eq 0) { break }
                $offset += $next
            }
            return $list
        }
        finally { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($buffer) }
    }
}

$first = @{}
foreach ($p in (Get-ProcessList)) { $first["$($p[0]) $($p[1])"] = $p[2] }
$clock = [System.Diagnostics.Stopwatch]::StartNew()
Start-Sleep -Seconds 1
$second = Get-ProcessList
$elapsed = $clock.Elapsed.Ticks * [Environment]::ProcessorCount

$cpu = @{}
$memory = @{}
foreach ($p in $second) {
    # Idle (id 0, no name) is not a program: it is the time no one used.
    if ($p[0] -eq 0) { continue }
    $name = ($p[1] -replace '\.exe$', '') -replace '[^A-Za-z0-9_.:-]', '_'
    if (-not $name) { continue }
    $memory[$name] = [long]$memory[$name] + $p[3]
    # A process that started during the second counts from 0; an id and name
    # together keep a reused id from counting against another program.
    $key = "$($p[0]) $($p[1])"
    $before = if ($first.ContainsKey($key)) { $first[$key] } else { 0 }
    $delta = $p[2] - $before
    $cpu[$name] = [long]$cpu[$name] + [Math]::Max([long]0, $delta)
}
if ($memory.Count -eq 0) { exit 1 }

$picked = @{}
foreach ($n in @($cpu.GetEnumerator() | Where-Object { $_.Value -gt 0 } | Sort-Object Value -Descending | Select-Object -First $top)) { $picked[$n.Key] = 1 }
foreach ($n in @($memory.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $top)) { $picked[$n.Key] = 1 }

$inv = [System.Globalization.CultureInfo]::InvariantCulture
foreach ($name in $picked.Keys) {
    $percent = if ($elapsed -gt 0) { 100.0 * $cpu[$name] / $elapsed } else { 0 }
    Write-Output "metric cpu_pct $($percent.ToString('0.0', $inv)) name=$name"
    Write-Output "metric memory_bytes $($memory[$name]) name=$name"
}
