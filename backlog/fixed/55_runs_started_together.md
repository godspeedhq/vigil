# 55. Windows: a tick's runs started together cost twice as much

Found on 2026-11-17 while looking at what a base-pack run costs on Windows
(backlog 52 left it at 3.4 to 5.4 CPU s a run on the test machines).

## The problem

**A run costs about twice as much CPU when it starts with the rest of its
tick.** With base pack 1.2.0 on Windows, every minute starts `cpu`,
`memory`, `network`, `services` and usually `vigil_sender` together, and
every fifth minute adds `disk`, `diskio`, `processes` and `host`: nine
PowerShell workers, each starting a job script, at the same instant (§8:
every due run starts now).

Measured on the laptop (i7-6700HQ, 8 threads, PowerShell 5.1), with the
nine base-pack runs started as the supervisor starts them (the same launch
records, naming `config.valid` and its digest), 3 rounds each. CPU is each
run's `cpu_seconds` from its state file: the worker and its job script.

| How the nine start | CPU per run | Wall time for all nine |
| --- | --- | --- |
| one at a time | **1.61 s** | 58.2 s |
| at most 2 at once | 1.74 s | 35.2 s |
| at most 3 at once | 1.96 s | 26.6 s |
| at most 4 at once | 2.37 s | 26.2 s |
| all 9 at once (today) | **3.22 s** | 20.6 s |
| all 9, started 2 s apart | **1.99 s** | 24.7 s |

An earlier run of the same comparison gave 1.70 s one at a time and 3.20 s
all at once.

The work each run does is the same in every row; only how many PowerShell
processes start at the same moment changes. Why that costs more CPU, not
just more wall time, is not proven here (likely the processes' start-up
work and .NET's background compiling competing for the same cores and
caches). It is measured on one 8-thread machine only; the 4-thread test
machines are not measured and may be worse.

## Options

**A. Space a tick's launches** (for example 2 s apart). The last row: about
38% less CPU per run, and the last run of a busy tick starts 16 s late.
**This breaks a rule you set:** VIGIL-002 and §8 say the supervisor never
delays a run to limit how many run at once. It would need that rule
changed (for example "a tick's launches may be spaced up to N seconds
apart"), on Windows only, or everywhere for consistency. A run's timing
also moves: `cpu` and `memory` would sample a few seconds later each tick.

**B. Build the smaller worker** proposed in backlog 52: the supervisor
writes the job's resolved settings into the launch's `[run]` section, so
the worker does not read the configuration. Estimated there at about 40% of
the worker's own CPU. It does not touch VIGIL-002 or any run's timing. It
should also shrink the together cost, since less start-up work competes,
but by how much is not measured.

**C. Spread the base pack's five-minute jobs** across the five minutes with
`cron` (for example `disk` at minute 1, `diskio` at 2, `processes` at 3,
`host` at 4, each every five minutes). A pack change only, no code: the
busiest tick goes from nine starts to six. The one-minute jobs still start
together, so it helps less than A.

**Recommendation:** B first, since it keeps your rule and cuts every run;
then measure again, together and alone. Add C if the five-minute ticks
still stand out. A only if you decide to change VIGIL-002.

## Decided (2026-11-17)

**B and C.** Build the smaller worker, and spread the base pack's
five-minute jobs across the five minutes. VIGIL-002 stays as it is: no
run is delayed.

## Built (2026-11-17)

**B, the smaller worker (Windows).** The supervisor writes the run,
resolved from the configuration it validated, into the launch's `[run]`
section (§4.3, updated); a worker with one does not read the
configuration. Vigil's own workers, a job with a secret, a command that
cannot be built or found, and a launch without a validated digest read it
as before.

**C, the spread pack.** Base pack 1.2.1 runs `disk`, `diskio`, `processes`
and `host` each on their own minute (`cron = 1/5 * * * *`, 2/5, 3/5,
4/5). On Windows a tick now starts at most six runs (the four one-minute
jobs, the sender and one five-minute job), not nine. Configurations
already holding the pack keep `run_every = 5m` until it is enabled again.

**Measured** on the laptop as above (the nine runs, launch records as the
supervisor writes them, 3 rounds each):

| How the nine start | Before | With `[run]` |
| --- | --- | --- |
| one at a time | 1.69 s | **1.49 s** (−12%) |
| all at once | 3.16 s | **2.64 s** (−16%) |

Less than backlog 52's estimate of about 40% of the worker: the average
includes `vigil_sender`, which has no `[run]`, and a run's cost includes
its job script and PowerShell's own start, which this does not touch.
Spreading the pack is not measured on its own; from the first table, six
runs at once should cost between the 4-at-once and 9-at-once rows.

**On the test machines** (2026-11-17, released in 0.10.1, which all five
run): the same nine runs from a scratch root in vigil-test's home, no
admin, 3 rounds each, PowerShell 5.1. Before is the same build with no
`[run]` section in the launch.

| Machine | One at a time | All nine at once |
| --- | --- | --- |
| Lenovo, Windows 11, i5-3320M (4 threads) | 4.45 → **3.70 s** (−17%) | 4.63 → **4.01 s** (−13%) |
| HP, Windows 11 (8 threads) | 2.32 → **2.05 s** (−12%) | 5.24 → 5.56 s (+6%) |
| Server 2025, i5 M 540 (4 threads) | 4.38 → **3.66 s** (−16%) | 5.58 → **4.83 s** (−13%) |

`base_services` failed in every round, with and without `[run]`: over SSH
these machines refuse the service manager. The HP's all-at-once row got
worse; with 3 rounds that is within its noise, but it is what was measured.
Starting together costs most on the 8-thread machines: about twice, on
the HP as on the laptop. On the 4-thread machines it costs less extra
(the Lenovo 4%, Server 2025 27%), but a run there costs more to begin
with.

## Done when

- The decision is recorded here.
- What is built is measured the same way (this table, before and after,
  on the laptop) and on the Windows test machines over SSH, and the
  numbers go in this file.
- The whole test suite passes on Linux, macOS and Windows.

## Reverted (2026-11-17): the smaller worker

The `[run]` section (B) is taken out again, on the owner's decision. It
saved 12 to 17% of a run's CPU, far less than the 40% estimated, and it
gave a Windows worker a second way to get its settings: every job setting
would have had to be added in two places, and a difference between them
would be a quiet bug. Vigil stays simple. The base pack's spread schedule
(C) stays: it is a pack change only. Released in 0.10.1, so 0.10.2 or later
goes back to one path; a launch record with a `[run]` section from 0.10.1
is read as any other, its section ignored.
