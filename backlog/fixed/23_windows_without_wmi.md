# 23. Windows: runs stuck and timeouts unproven where WMI refuses

Found on the first real Windows test machine, with Vigil run over SSH as a standard user.

WMI refuses a network logon that is not an administrator's: an SSH session with a key, or a scheduled task set to run without a stored password. Vigil read process facts and the boot time through WMI only, so there:

- **No run could be concluded.** Once a worker let go of its token, the supervisor asked WMI whether any process still carried the run id. The answer was always "cannot tell", so finished runs stayed RUNNING.
- **No timed-out run could be ended.** Its job process could not be proven to be the run's, so the run was held as uncertain and nothing was killed. That is the safe direction, but timeouts never took effect.
- **Everything was slow.** WMI takes about five seconds to refuse, every time. A worker paid it for the boot id, and the supervisor paid it for every job on every tick, so one tick took tens of seconds.
- **The boot id was empty**, so a reboot could not be told apart from a crash.

## Fixed

- **The boot id comes from the kernel** (`NtQuerySystemInformation`), with WMI as the fallback. Both give the same time to the second, so ids written before the change still match. This was checked on two machines.
- **Process facts fall back to the kernel when WMI refuses:** name, start time, parent and command line (`Get-VigilProcessInfo`, and `Test-VigilRunProcess`). The kernel, like WMI, cannot read another user's processes. A worker's command line that cannot be read no longer counts as proof: the job's parent must then match the worker.
- **The refusal is remembered**, so each process asks WMI at most once.
- **The helper is compiled with `Add-Type`,** in about 0.3 s, once per process, when first needed.
- **Tests:** `VIGIL_TEST_NO_WMI=1` takes the kernel's route. CI runs Max-Runtime and Uncertain that way on PowerShell 5.1.
- **Measured** on the test machine over SSH:
  - every result is correct, and timeouts are proven and ended
  - a tick keeps to its 10 s
  - locally, Uncertain.ps1 took 70 s on the kernel's route, against 152 s with WMI

## Not fixed

`vigil start` in user mode still launches the supervisor through `Win32_Process.Create`, so that it is detached and hidden, as at logon. `vigil uninstall`'s last clean-up step does the same. Over SSH as a standard user, both still fail. A launch without WMI that survives the SSH session ending needs its own work, if anyone needs it.
