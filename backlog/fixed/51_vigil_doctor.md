# 51. vigil doctor: is this machine running Vigil well?

Found on 2026-11-15, while working out why the Windows 11 test machine sat at
100% CPU. Nothing in Vigil could answer the question. A one-off probe script,
run from an elevated prompt, could:
it watched the service's process tree for 5 minutes and checked the usual
suspects on the machine. That probe found the cause (Vigil's own runs, see
backlog 52), and it ruled out the machine. An operator should be able to ask
Vigil the same thing.

## The problem

**Vigil can't tell an operator what it costs, or whether the machine slows
it down.** `precheck` checks that runs *can* work; nothing checks how well
they *do*. What the probe had to find out by hand:

- **What Vigil itself uses.** Five base-pack jobs on two 4-thread machines:

  | (0.7.0) | Windows 11 | Server 2025 |
  | --- | --- | --- |
  | Vigil's process tree | 1.73 cores | 1.66 cores |
  | a base-pack run | 12.2 CPU s | 11.8 CPU s |
  | a `vigil_sender` run (25 in 5 min) | 10.0 CPU s | 9.2 CPU s |

  Neither `vigil status` nor the state files say any of this. The run's
  duration is recorded, its CPU isn't.
- **Whether PowerShell starts fast here.** A bare `powershell.exe` cost 0.2
  CPU s on Windows 11 and 0.45 on Server 2025. On Server 2019 (2026-11-13),
  with .NET's native-image (NGEN) queue not yet run, PowerShell took 3.3 s to
  start, 30 s under load, and slow ticks failed tests until `ngen
  executeQueuedItems` was run. Nothing in Vigil would have said so.
- **What else on the machine weighs on every run:** Defender's real-time
  scanning and AMSI (MsMpEng used 2.7% and 4.2% of the CPUs above), and
  PowerShell logging policies (script block logging, module logging,
  transcription), which make every script costlier.

## Proposed

**`vigil doctor`**: read-only, like `precheck`, and printed the same way
(`ok`, `note`, `WARN` lines). It changes nothing and fixes nothing: each line
says what it found and, where it applies, what the operator can do.

- **What Vigil costs.** Each run records the CPU it used in its state file,
  as `cpu_seconds`, from the OS at the end of the run:
  - **Linux and macOS:** the worker and every process the run started
    (the OS adds up children that have been waited for).
  - **Windows:** the worker and its job process. A job's own children are
    not counted: that would take a Windows Job Object, more machinery than
    Vigil wants (decided 2026-11-15). The specification says so; the base
    pack's scripts start none.

  `doctor` lists each job's last run (CPU, wall time, how often it runs)
  and works out how many cores Vigil keeps busy, with `vigil_sender` and
  Vigil's other workers included: a `note` above a quarter of one core, a
  `WARN` above half of one (decided 2026-11-15: after backlog 52, the three
  Windows test machines measured 0.46 to 0.76 cores, and a check that
  always warns is soon ignored). The same field could later become a
  metric; not in this backlog.
- **How fast the shell starts.** The median of three bare starts of each
  runner's shell (`bash`, `powershell.exe`, `pwsh`), CPU and wall. `WARN`
  above 1 s.
- **Windows:**
  - **NGEN:** whether a fresh `powershell.exe` loads native images
    (`System.Management.Automation.ni.dll`), and whether the NGEN queue has
    items waiting. `WARN` with the command to run (`ngen executeQueuedItems`,
    elevated).
  - **Defender:** whether real-time protection is on and whether any
    exclusion covers Vigil's root. A `note` only: whether to exclude
    anything is the administrator's decision, and `doctor` never
    recommends it. Exclusions are hidden from non-administrators; then it
    says so.
  - **PowerShell logging policies:** a `note` naming each one that is set.
- **Exit code:** 0, or 1 when anything is `WARN`.
- **`precheck` also gets the NGEN check**, as a `note` (never a failure), so
  an install or `precheck` on a fresh Windows machine says it once, where an
  operator looks first. The same check function serves both.

Linux and macOS get the same command: the cost per job, and the shell start.
The Windows-only checks are left out there.

## Done when

- `vigil doctor` is in `SPECIFICATION.md` (§18.5, and its own section), with
  example output, on all three platforms.
- Every run, Vigil's own included, writes `cpu_seconds` to its state file,
  and a test checks it is there and not zero for a job that does work.
- On the Windows test machines, `doctor` reports roughly what the probe
  measured (cores Vigil keeps busy, CPU per run), from an elevated prompt and
  from a standard user's, and over SSH (WMI refused), saying what it couldn't
  read.
- A Windows test machine with NGEN removed or queued is reported (`WARN`) by
  `doctor`, and as a `note` by `precheck`; one with native images is `ok`.
  If no machine can be put in that state safely, the check's logic is tested
  with a fault hook, and that's stated.
- The integration tests cover `doctor` on Linux, macOS and Windows.

## Built (2026-11-16)

**What it prints** (§16.7): what Vigil's runs cost in the last hour, per
job and in cores busy (`ok`, a `note` above a quarter of a core, `WARN`
above half); how fast each shell a run starts takes to start; and on
Windows, .NET's native images, Defender and PowerShell's logging policies.
`precheck` gives the native-images finding as a `note`.

**Every run records its CPU**, Vigil's own included: `cpu_seconds` in its
state file (§12.2) and at the end of its `run end` line (§13.1):

```text
2026-11-16T11:59:17Z 20261116T115908Z-23544-657 run end succeeded in 5s, cpu 7.95s
```

**Each run's figure is added up, never the last run's multiplied.** The
first build multiplied each job's last run by its runs in the hour. On the
HP that came to 0.56 cores where the kernel measured 0.673: the base jobs
matched (0.438 against 0.437), but `vigil_sender`'s last run cost 1.25 CPU
s where its hour averaged 2.38. Runs of one job vary that much, so `doctor`
now adds up the hour's `run end` lines.

**Measured against the kernel, on the HP** (Windows 11, 8 threads, base
pack), as vigil-test with no elevation: a foreground supervisor on a
scratch root, its process tree measured for an hour from the kernel
(`GetProcessTimes` at each process's exit), then `vigil doctor` on the same
root:

| job | runs, kernel | runs, doctor | CPU, kernel | CPU, doctor |
| --- | --- | --- | --- | --- |
| `vigil_sender` | 355 | 355 | 842.28 s | 802.94 s |
| `base_network` | 60 | 60 | 373.81 s | 360.71 s |
| `base_cpu` | 60 | 60 | 373.66 s | 360.07 s |
| `base_memory` | 60 | 60 | 372.50 s | 359.45 s |
| `base_services` | 60 | 60 | 348.27 s | 334.90 s |
| `base_disk` | 12 | 12 | 77.14 s | 74.38 s |
| **cores** | **0.663** | **0.64** | | |

`doctor` reads about 4% low: what a worker spends after it measures itself
(writing the log line and exiting), and its console host. Matching run ids
in a 5-minute run, each run's `cpu_seconds` was within 0.1 s of the
kernel's. The supervisor's own CPU (0.031 cores) is not a run's and is not
counted; §16.7 says so.

**And as the real service, from an elevated prompt** (the HP's system
service, LocalSystem, on this branch): `Probe-Vigil.ps1` watched the
service's process tree for an hour, then `vigil doctor` ran at once:

| job | runs, kernel | runs, doctor | CPU, kernel | CPU, doctor |
| --- | --- | --- | --- | --- |
| `vigil_sender` | 356 | 357 | 721.94 s | 685.46 s |
| `base_services` | 60 | 60 | 328.41 s | 312.26 s |
| `base_network` | 59 | 60 | 318.47 s | 310.51 s |
| `base_memory` | 60 | 60 | 315.55 s | 302.51 s |
| `base_cpu` | 60 | 60 | 311.83 s | 300.59 s |
| `base_disk` | 12 | 12 | 63.89 s | 61.39 s |
| **cores** | **0.572** | **0.55** | | |

The same 4% (the windows start 13 s apart, hence a run more or less), and
the same verdict: a `WARN`, above half a core. Elevated, `doctor` also read
Defender: `real-time protection is on and scans each script a run loads;
no exclusion covers C:\ProgramData\Vigil`. The kernel's figure for the
whole tree, the service's supervisor included, was 0.60 cores.

**Without elevation** against the real 0.8.0 services (Lenovo, Server 2025,
HP, over SSH): `doctor` named the configuration it could not read
(`WARN`), and still measured the shell start and native images; Defender
said it could not be read from that session.

**Native images:** CI's runners and every test machine have them, so the
missing case is tested with the stand-in `VIGIL_TEST_NGEN_MISSING`
(§22.4.6): `doctor` gives a `WARN` with the `ngen.exe` command, `precheck`
a `note` (and fails while the stand-in is set).

**Tests:** `tests/integration/doctor.sh` (Fedora bash 5.3 and macOS bash
3.2: 24 passed each) and `Doctor.ps1` (Windows PowerShell 5.1 and 7: 31
passed each), both in CI. The new check on the `run end` line found that
the Windows test's job had never run (its configuration had no `.ps1`
runner), though the old checks passed.
