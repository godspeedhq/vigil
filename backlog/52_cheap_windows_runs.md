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

- **Make every run cheaper first, the sender's included; pace the sender
  later only if needed** (decided 2026-11-15). The sender still starts on
  any tick where the spool isn't empty, as §4.5 says. Pacing it (for
  example at most one every 60 s, or sooner when a job's events are
  waiting) is a separate change to §4.5 that can be added on top, if the
  measurements after this backlog show it's still needed. At one sender
  a tick, a 2-CPU-second sender alone is about a sixth of a core on these
  machines.
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

## `max_runtime` is unaffected

The supervisor enforces it, not the worker: the worker writes
`deadline_epoch` (its start plus `max_runtime`) into the run's state, and the
supervisor ends the run's process tree on each tick past it. The clock
starts once the worker has loaded, read the configuration and claimed the
run, so today's startup isn't counted against the limit, and a cheaper start
makes no run reach it sooner. A worker slow to start isn't abandoned either:
a started worker carries its run id however slow it is to claim (§11.2).

It helps a little: the base pack's `max_runtime` is 30 s, and a base-pack
run took 18 to 19 s of wall time on both machines, mostly Vigil's own work
(the script sleeps 1 s). Under load that margin is thin.

## Drawbacks, and how each is contained

1. **Loading only some libraries can break a rare path.** A path calling a
   function from a library it didn't load fails only when that path runs: a
   job with a `secret:` reference needs the secret-store code, `vigil_fetch`
   needs Fetch, `vigil_update` needs SelfUpdate. The common case could pass
   while a rare one fails in production.
   **Contained by** loading by worker kind (a job run, the sender, fetch,
   logs, update), not by guessing per function; a test that checks
   statically that every function each kind calls is defined in what it
   loads; and the integration tests, which already run those paths.
2. **Validating once trusts the supervisor's check.** Today the worker
   re-checks the configuration and refuses a file that became broken or
   changed. In local mode someone could edit `vigil.config` between the
   launch and the claim (a second or two); the worker would then read a
   file the supervisor never validated.
   **Contained by** the launch naming the exact validated configuration, as
   fetch mode already does with the active one: the supervisor keeps a copy
   of the last valid local configuration in `state\`. That closes the window
   rather than narrowing it, and is more consistent than today, where a run
   can pick up an edit the supervisor hasn't accepted yet. A small change to
   `SPECIFICATION.md`.
3. **Two paths.** `vigil run` by hand has no supervisor, so it still
   validates fully.
   **Contained by** keeping that path the existing code, and testing both.
4. **Windows and POSIX internals drift apart a little.** Bash needs none of
   this: a run there is already cheap.
   **Contained by** keeping the behaviour the same on every platform (the
   conformance and integration suites check it); only Windows' internals
   differ.
5. **The change touches §11's core**, the claim, token and state code, the
   most safety-critical part of Vigil.
   **Contained by** the crash, orphan and reboot tests passing unchanged
   (Done when, below).

## Done when

- On both Windows test machines, with the base pack, the same 5-minute
  probe measures an ordinary base-pack run and a `vigil_sender` run at
  **2 CPU s or less** each on PowerShell 5.1, and Vigil's whole process
  tree at well under half a core (it was 1.7). The before and after
  numbers go in this file.
- Those numbers say whether pacing the sender is still worth a change to
  §4.5; if so, it is offered as its own backlog, not done here.
- The whole test suite passes on Linux, macOS and Windows; the §11 crash,
  orphan and reboot tests pass unchanged.
- Linux and macOS cost no more than before.

## Built so far (2026-11-15): about 70% less, not yet 2 s

**What a run's cost turned out to be.** Running a worker's stages twice in
one process, the second pass cost a twentieth of the first (validating:
0.78 CPU s, then 0.03). Of one run's 7.7 CPU s on a laptop, the thread
running the script used 1.6 s, and the rest went to background threads:
PowerShell compiling the code it runs, for a process that then exits. Not
the garbage collector (the same with concurrent GC off), and the same on
PowerShell 7. So the cost follows how much code a run executes, and
skipping work saves more than that work's own time.

**What changed:**
- **A run uses the configuration its launch names** (§4.3, updated): the
  last valid local one (`state\config.valid`) or the active one. On
  Windows the launch also carries `config_sha256`, the digest the
  supervisor validated, and a worker whose file still has it does not
  validate it again; otherwise it validates it. The supervisor keeps
  `config.valid` only when it is still what it validated (it used to read
  the file a second time to copy it).
- **The worker takes the boot id from its launch** instead of building
  the kernel call with Reflection.Emit again (0.9 CPU s on its own).
- **A worker loads only its kind's libraries**: 12 to 15 of the 25, per
  `$workerLibs` in `vigil.ps1`. `tests/Test-WorkerLibraries.ps1` (in CI)
  reads the code and fails if a kind can reach a function or script
  variable from a library its list leaves out.
- **A bug fixed on the way, on all three platforms:** while an edit was
  rejected, the supervisor kept the last valid configuration (§16.3), but
  every run it launched read the rejected file and refused. A new test in
  `Supervise.ps1` and `supervise.sh` failed on main (Windows and Fedora)
  and passes now. Linux and macOS read the named configuration too and
  still validate it (cheap there).

**Worker CPU per run** (the worker process alone, median of 5, started as
the supervisor starts it, base pack, PowerShell 5.1):

| | laptop, main | laptop, now | Windows 11 box, main | Windows 11 box, now |
| --- | --- | --- | --- | --- |
| `base_memory` | 4.95 s | 1.38 s | 11.66 s | **3.53 s** |
| `vigil_sender` | 5.47 s | 1.19 s | 8.72 s | **2.58 s** |

Wall time per worker on the laptop went from 10 s to 6.3 s; most of what
is left there is waiting while each script file is scanned on load.

**What is left, on the Windows 11 box** (fresh processes stopped at each
point): PowerShell itself 0.38 s; loading the libraries and reading the
configuration 1.14 s; then 0.1 to 0.4 s in each later step. Loading the
libraries alone is now about 0.25 s over a bare start, so trimming more
of them saves little. Reaching 2 s means running less PowerShell per run
(a smaller worker, the supervisor resolving more into the launch), or a
warm process for Vigil's own workers: each a decision for the user, not
taken here.

**Not measured yet:** the 5-minute probe on the service, which needs this
build installed as the service on the test machines. The job scripts
(`cpu.ps1`, `memory.ps1`) still build their Windows calls with
Reflection.Emit, which the boot id showed costs a fresh process most of a
second; they are part of a run's tree and not changed here.
