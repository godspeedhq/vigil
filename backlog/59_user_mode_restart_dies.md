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
