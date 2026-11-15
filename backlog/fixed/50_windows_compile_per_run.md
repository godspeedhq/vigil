# 50. Windows: a C# compile on every run

Found on 2026-11-15 on the Windows 11 test machine (4 CPUs), running Vigil
0.7.0 as a system service with only the base pack enabled. The machine was at
100% CPU. Most of that turned out to be Docker Desktop's VM (`vmmem`, one
core busy since boot), not Vigil. But watching the processes showed what
Vigil itself costs there.

## The problem

**Every Windows run starts the C# compiler.** In one minute, from an
elevated prompt (the per-minute counts include `vigil_sender`; the 10-second
CPU sample missed the short-lived workers):

```
== new processes in 60 seconds, by name
  14 conhost
  14 powershell
   8 csc
   4 cvtres
```

The jobs were the base pack's four one-minute jobs and `vigil_sender`. Two
sources compile:

1. **Vigil's worker (`app/lib/windows/Worker.ps1`).** Every worker writes
   `boot_id` into the run's state (`Invoke-VigilWorker`, for job runs and
   Vigil's own `vigil_sender`, `vigil_fetch`, `vigil_logs` and
   `vigil_update`). `Get-VigilBootId` asks the kernel first, through
   `Initialize-VigilNative`, which compiles the `VigilNative` class with
   `Add-Type -TypeDefinition`. The comment says "Compiled once per process",
   but every run is a new process, so it compiles every run. The supervisor
   already works the boot id out once, at start (`Supervisor.ps1`,
   `Boot = Get-VigilBootId`), and writes it into each run's launch file
   (`boot_id = ...`). So the worker recomputes a value it was handed.
2. **The base pack's `cpu.ps1` and `memory.ps1`.** Each runs `Add-Type` on
   every run, to call one Windows function: `GetSystemTimes` and
   `GlobalMemoryStatusEx`.

So with the base pack alone, Windows compiles about six times a minute, all
day. It is a background cost on every Windows install, and it grows with
every job added and every shorter interval.

**How much each compile costs isn't measured yet.** In one rough check on
the same machine (as vigil-test, while `vmmem` held a core), a bare
`powershell -Command 1` took 0.38 s, and one that also compiled
`VigilNative` took 0.86 s: about 0.45 s more per run. The compiler's own CPU
wasn't captured. On 2026-11-14, a user-mode demo there, with a fetch every
30 s and two one-minute jobs, showed workers at 8 to 9 CPU seconds each.
That machine was loaded, so treat those numbers as a sign, not a
measurement.

## Proposed

- **The worker takes the boot id from its launch.** The supervisor already
  writes `boot_id` into the launch file, and the worker already opens that
  file to claim the run (§11.2). A worker started without a launch file (`vigil run` by hand) still
  works it out itself. Nothing changes on Linux or macOS, where
  `/proc/sys/kernel/random/boot_id` or `sysctl` costs nothing.
- **The compile is done only when it's really needed.** `Initialize-VigilNative`
  stays for the paths that need the kernel because WMI was refused (process
  info, process tree, starting a detached process). A run that never
  takes those paths never compiles.
- **The pack scripts call Windows without the compiler.** For example,
  `memory.ps1` through a .NET type that already exists (one with total and
  available physical memory), and `cpu.ps1` through a P/Invoke method built
  in memory with `System.Reflection.Emit` (`DefinePInvokeMethod`), which
  needs no `csc`. Whichever way is chosen, it must keep working without
  WMI (an SSH-started Vigil), on PowerShell 5.1 and 7, and in every
  language of Windows.

## Done when

- Over a few minutes with the base pack enabled, `csc.exe` starts **zero**
  times on Windows PowerShell 5.1 and PowerShell 7, as a system service and
  in user mode, where WMI answers. A test checks it: run a job and the
  base-pack jobs, and assert no `csc` child was started.
- The boot id in each run's state is the same as before, and the existing
  §11 crash, orphan and reboot tests still pass, including over SSH (WMI
  refused).
- The cost per run is measured before and after (worker CPU seconds and
  wall time, on a quiet machine), and the numbers go in this file.
- The base pack's `cpu.ps1` and `memory.ps1` give the same values as before
  (the base-pack tests).

## Built (2026-11-15)

**What changed:**
- **The boot id** (`Get-VigilBootId`, `app/lib/windows/Worker.ps1`) calls
  `NtQuerySystemInformation` through a P/Invoke built in memory with
  `System.Reflection.Emit` (`DefinePInvokeMethod`), not through the
  compiled `VigilNative` class. Neither the supervisor nor the worker
  compiles for it any more. `VigilNative` stays, without its boot-time
  method, for the paths that need the kernel because WMI refused.
- **The base pack's `cpu.ps1` and `memory.ps1`** call `GetSystemTimes` and
  `GlobalMemoryStatusEx` the same way. `MEMORYSTATUSEX` is read from a
  64-byte buffer. The base pack is now 1.1.2.
- **The proposal changed in one way:** the worker doesn't read the boot id
  from its launch file. With no compile left in `Get-VigilBootId`, that
  second path wasn't needed, and the supervisor and `vigil run` got the
  fix too.

**Tested on the Windows 11 machine** (4 CPUs, over SSH, so WMI refused):
- **Same answers.** Through Emit, the boot time matched the kernel's
  (`2026-11-14T23:04:44Z`). Memory (16,080 MB total) and the CPU times
  matched `Add-Type`'s, on PowerShell 5.1.22621 and 7.6.10.
- **`tests/integration/Base-Pack.ps1` has a new check:** it watches the
  test's own process tree (from the kernel, so another Vigil on the
  machine doesn't count) and fails on any `csc.exe` while the five base
  jobs run. On main it failed, as it should; with the fix it passed:

  | | Windows PowerShell 5.1 | PowerShell 7 |
  | --- | --- | --- |
  | main | 7 × `csc` | 2 × `csc` (the job scripts, run by `powershell.exe`) |
  | this change | **0** | **0** |

  `base_services` failed on both trees, as it does over SSH (the service
  manager refuses SSH sessions).
- **PowerShell 7 compiles inside the process**, with Roslyn, which it
  loads at start whether or not it compiles. So the test can't see it
  there; the check covers the job scripts. The cost below shows the
  difference.

**Cost per `vigil run`**, the CPU of the run's own process tree, median of
5 (the machine was busy: Docker Desktop's VM held about one core):

| | main | this change |
| --- | --- | --- |
| PS 7, `base_memory` | 18.92 s | 16.31 s |
| PS 7, `base_cpu` | 19.59 s | 16.86 s |
| PS 7, `base_disk` | 19.13 s | 16.16 s |
| PS 5.1, `base_memory` | 16.11 s | 15.94 s |
| PS 5.1, `base_cpu` | 16.22 s | 15.81 s |
| PS 5.1, `base_disk` | 16.03 s | 16.03 s |

So on PowerShell 7 a run costs about 3 CPU seconds less (about 15%). On
Windows PowerShell 5.1 these numbers show no difference beyond the noise.
But the measurement missed the `csc` processes (it counted none, even on
main), so their own CPU isn't in them. The test's watcher did catch them:
this change removes 7 compiler starts per 5 runs there.

**What this found: a run costs about 16 CPU seconds on that machine,
compile or not.** Timed stage by stage in one process (PowerShell 5.1,
with this change):

| Stage | CPU | Wall |
| --- | --- | --- |
| Load the 25 libraries | 0.48 s | 0.82 s |
| Parse `vigil.config` | 0.45 s | 0.65 s |
| Validate it (`Test-VigilConfig`) | 1.67 s | 1.04 s |
| `Get-VigilWorkerContext` (parses and validates again) | 1.59 s | 0.49 s |
| `Get-VigilBootId` | 1.16 s | 0.31 s |
| `New-VigilLaunch` (and again) | 1.70 s | 0.60 s |
| `Invoke-VigilWorker` | 6.34 s | 2.75 s |

Two things stand out:
- **CPU runs at 2 to 3 times wall time all through.** Something in the
  process works in parallel throughout.
- **`vigil run` validates the configuration three times.**

Not followed up here: it is outside this backlog, and it is the user's to
decide whether it becomes one.
