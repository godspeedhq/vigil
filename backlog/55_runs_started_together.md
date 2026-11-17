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

## Done when

- The decision is recorded here.
- What is built is measured the same way (this table, before and after,
  on the laptop) and on the Windows test machines over SSH, and the
  numbers go in this file.
- The whole test suite passes on Linux, macOS and Windows.
