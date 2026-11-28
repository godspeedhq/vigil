# A Windows check of the configuration's source cost seconds of CPU

Found by the fleet test (bug B3 in `tests/integration/backends/reports/runs/2026-11-26/fleet-run2/BUGS.md`): on Windows 11, each `vigil_fetch` run used 5 to 8 seconds of CPU in run 1, and 11 to 14 the next day on the HP, against 0.55 to 0.80 on Linux and about 1.1 on macOS. At a 30-second `check_every` that is a third of a core, to find nearly every time that nothing has changed.

## Where it went

Measured on the HP (Windows 11, 8 logical CPUs) on a copy of its fleet instance, by the process's own CPU time:

| Step | CPU, in a fresh process |
| --- | --- |
| PowerShell starting | 0.35 s |
| Loading the fetcher's 13 libraries | 0.1 to 1 s (3.7 when Defender first scans a new copy) |
| Parsing and validating the local pointer file | 0.4 to 0.8 s |
| **Validating the fetched configuration** | **5.5 s**, then 1.5 s if done again in the same process |
| A `git` process, started and waited for | about 0.1 s (1 s the first time) |

The validator is plain PowerShell, and Windows PowerShell 5.1 compiles a script's code the first time it runs it. Every check is a new process, so every check paid that first time, to validate a file that was, nearly always, the one it had validated 30 seconds before. `git` itself is not counted: a worker counts its own process.

## The fix

A configuration that passes validation is recorded beside its kept copy, as `state/configs/<sha256>.checked`: the first line names this Vigil (a digest of its Windows scripts) and whether the file came from a source; then the jobs found invalid. When a check finds the same file again, under the same Vigil and from the same place, it uses the record instead of validating again. A new file, any change to Vigil's scripts (an update, or an edit), or a file that failed, is validated as before. A record goes when its configuration's copy goes.

The bash fetcher validates in well under a second and is unchanged.

| A whole fetch, in a fresh process, nothing changed | CPU |
| --- | --- |
| 1.5.3 | 4.3 to 11.1 s, median 7.1 |
| With the fix | 1.6 to 6.3 s, median 2.9; 1.6 to 1.8 when the machine is quiet |

Five runs each, alternating, on the HP while its five fleet containers ran, so single runs vary. What is left is PowerShell itself starting, its libraries, the pointer file and `git`.

`tests/integration/Fetch.ps1` checks that the record is written, and that a record from another Vigil is not used: the file is validated again and recorded anew.

## Closed

2026-11-27.
