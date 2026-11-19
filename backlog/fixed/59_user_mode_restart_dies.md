# 59. Windows user mode: a supervisor started by `vigil restart` dies

Seen twice in CI, on 2026-11-18, in `tests/integration/Service.ps1`, user
mode: `vigil restart` succeeds, and `vigil status` then says `inactive`.
Not reproduced on the Windows 11 laptop. In about 50 runs of that job it
happened in these two, once on each PowerShell:

- run 44361165213, PowerShell 7 (the check printed nothing then);
- run 44419169617, PowerShell 5.1, with the diagnostics of #200.

## What the second one shows

- `restart` stopped the old supervisor (pid 1108) and started a new one
  (pid 1240), which logged `supervisor started` at 23:24:00 and decided a
  slot at 23:24:02.
- That tick never rewrote `jobs.log`, and about two seconds later no
  `supervise` process was left at all. The lock still named pid 1240.
- No `supervisor stopped` line. The supervisor writes one in a `finally`
  on any exit it controls, even an exception, so the process was ended
  from outside or crashed hard (a fail-fast, a stack overflow).
- Only ever after a `restart`, never after a `start`, though both start
  the supervisor the same way.

## What it is not, so far

- In user mode, `start` and `restart` launch the supervisor detached
  through WMI (`Win32_Process.Create`). On the laptop a process started
  that way is in no job object (its parent is `WmiPrvSE.exe`), and 12 of
  12 lived for 40 seconds. So it is not, there, a job that kills its
  processes when the WMI provider host goes.

## Next

In user mode the supervisor's stdout and stderr go nowhere, so whatever
it said as it died is lost. System mode sends both to
`logs\supervisor\service.log` (NSSM). Doing the same for the Run entry
and for `start`/`restart` in user mode would let the next occurrence say
why. Until it is understood, a user-mode `restart` on Windows can, rarely,
leave no supervisor running until the next logon or `vigil start`.

## Built

The supervisor did not die: `restart` never started one. The run's log
holds two supervisors only, 1108 (from `service install`) and 1240, so
1240 was the one `start` launched, and `restart` ended it mid-tick at
23:24:02. `restart` then asked whether a supervisor was running, to start
one if not, and was told yes: the killed 1240 still held
`state\supervisor.lock`, and WMI still listed it. It started nothing and
said "restarted vigil".

A killed process's handles are closed after it has left the process list,
so its lock can outlive the wait on it. On the laptop, on PowerShell 7,
the lock was still held right after `Stop-Process -Force` and that wait in
29 of 30 kills, for up to 13 ms. A restart failed only when WMI also still
listed the process in that moment, which is rare.

- `stop`, `restart` and `service remove` (user mode) now kill the
  supervisor and return only once that process no longer passes the proof
  of a running supervisor (lock held, pid in it, command line), within
  30 s or with an error.
- §18.9 says so.
- `tests/integration/Service.ps1`: three restarts in a row in user mode,
  each must leave a supervisor with a new pid; the test job now holds for
  fifteen minutes, as five restarts on a slow machine outlasted five.
