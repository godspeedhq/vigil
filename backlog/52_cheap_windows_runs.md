# 52. Windows: a run costs 10 to 12 CPU seconds

Found on 2026-11-15 by a probe run from an elevated prompt on two Windows
test machines, each running Vigil 0.7.0 as a system service with only the
base pack enabled. The probe watched the service's process tree for 5
minutes and read each process's CPU from the kernel when it ended.

## The problem

**Vigil keeps 1.7 cores busy, all day, for five small jobs:**

| | Windows 11 (i5-3320M, 4 threads) | Server 2025 (i5 M 540, 4 threads) |
| --- | --- | --- |
| Vigil's process tree | **1.73 cores** (43% of the machine) | **1.66 cores** (41%) |
| `vigil_sender`: runs in 5 min, CPU each | 25, 10.0 s | 25, 9.2 s |
| a base-pack run: CPU, wall | 12.2 s, 19 s | 11.8 s, 18 s |
| the supervisor | 11.7 s in 5 min | 12.4 s in 5 min |
| a bare `powershell.exe -Command exit` | 0.2 CPU s | 0.45 CPU s |

On Windows 11 that, with Docker Desktop's VM (0.95 core), held the machine
at 100%. Server 2025 has nothing else running, so it looked fine; it isn't.

**It isn't the machine.** On both, .NET's native images load (NGEN is done),
no PowerShell logging policy is set, and Defender's own process used 2.7%
and 4.2% of the CPUs. **It isn't PowerShell starting:** a run starts two
(the worker and the job script), about 0.4 to 0.9 CPU s. The compiles that
0.7.0 still runs (backlog 50, fixed on main) cost under 1 s a run. **The
rest, about 10 s a run, is Vigil's own PowerShell code.**

Where it goes, from a stage-by-stage timing of `vigil run` on Windows 11
(2026-11-15, PowerShell 5.1, main after backlog 50):

| Stage | CPU | Wall |
| --- | --- | --- |
| load the 25 libraries | 0.48 s | 0.82 s |
| parse `vigil.config` | 0.45 s | 0.65 s |
| validate it | 1.67 s | 1.04 s |
| `Get-VigilWorkerContext` (parses and validates again) | 1.59 s | 0.49 s |
| `Get-VigilBootId` | 1.16 s | 0.31 s |
| `New-VigilLaunch` (and again) | 1.70 s | 0.60 s |
| `Invoke-VigilWorker` | 6.34 s | 2.75 s |

Three things stand out:

1. **`vigil_sender` starts on almost every tick.** It starts on any tick
   where the spool isn't empty and no sender is alive (§4.5), and the
   supervisor writes its own events every tick, so the spool is never empty.
   That is half of Vigil's CPU, and it happens with no jobs at all.
2. **Every worker loads all 25 libraries**, the ones for `init`, `self
   update`, `pack`, `config`, `precheck` and `service` among them.
3. **Every worker parses and validates the whole configuration**, which
   the supervisor has already validated, and in fetch mode does it twice
   (the local file, then the active one). `vigil run` does it three times.

On Linux and macOS a run is a few bash processes and costs little; the same
design is cheap there. Nothing here changes how a run is owned: each run
stays its own process, with its own token, state and log (§11).

## Proposed

- **Pace the sender.** *Decision needed (it changes §4.5 on every
  platform):* for example, start a sender at most every 60 s, or sooner
  when a job's events are waiting; or start one only for a job's events,
  with the supervisor's riding along. Until decided, this item waits.
- **The worker loads only what it needs.** `vigil.ps1` loads the libraries
  per command: the worker path needs the config, worker, outcome, events,
  metrics and recovery code, not `init` or `self update`.
- **Validate once.** The worker trusts the configuration the supervisor
  launched it with: the launch record already names the active
  configuration in fetch mode; in local mode the worker checks only what
  its own run needs (its job's section, the paths, the runner). A
  configuration edited between launch and run is still caught: the
  supervisor validates every change before it uses it (§16.3). How exactly
  to keep this safe is part of the work, and `SPECIFICATION.md` is updated
  if anything a worker checks moves.
- **Then profile what's left**, stage by stage, and cut the largest.

## Done when

- On both Windows test machines, with the base pack, the same 5-minute probe measures Vigil's process tree at
  **under 0.25 cores**, and an ordinary base-pack run at **2 CPU s or
  less** on PowerShell 5.1. The before and after numbers go in this file.
- `vigil_sender`'s pace follows whatever is decided, on all three
  platforms, with the spec and tests updated.
- The whole test suite passes on Linux, macOS and Windows; the §11 crash,
  orphan and reboot tests pass unchanged.
- Linux and macOS cost no more than before.
