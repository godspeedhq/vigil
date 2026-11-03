# 27. Windows: taskkill refused where WMI is, so nothing timed out was ended

Found by the sources tests (backlog task 25) on the Windows test machine, with Vigil run over SSH as a standard user: the logon #63 (backlog/fixed/23) is about.

`taskkill` asks WMI for the processes, so under a logon WMI refuses it answers "Access denied". That includes ending a process this account started and may end. .NET's `Process.Kill()` ends the same process at once. Vigil ended process trees with `taskkill /T /F` in five places, and none of them worked there:

- **A fetch that timed out** (spec 16.5). An sftp fetch was left running past its 10-second limit. It held the fetcher's batch file, so the fetch failed with a misleading reason ("The process cannot access the file 'batch'…"). It also held the caller's output pipe, so `vigil supervise --once` never returned.
- **A run past `max_runtime`** (spec 10.3), once its process was proven to be the run's.
- **`vigil uninstall`**, for the proven runs.
- **A secret helper, or a store's CLI, that timed out.**

## Fixed

- **`Stop-VigilProcessTree`** (Worker.ps1) tries `taskkill /T /F` as before, skipped once WMI has refused this process. When it's refused, it finds the tree from the kernel (the snapshot of #63) and ends it with `Process.Kill()`, children first.
- **Children by start time:** a process counts as a child only if it started after its parent, so a reused pid can never draw an unrelated process in. Another account's processes can't be read, so they're left alone.
- **All five places** use it.
- **Checked:**
  - Over SSH on the Windows machine, a parent and both its children were ended.
  - Max-Runtime passes 10 of 10 both with WMI and without it (`VIGIL_TEST_NO_WMI=1`, which CI runs on 5.1 since #63), now with the native path.

## Also found: sftp never exited after an error

With the kill fixed, every sftp failure still waited out the fetch timeout on Windows. Windows' OpenSSH (sftp.exe, and ssh.exe when git uses it) never exits after an error while its standard error is a pipe. Vigil's fetcher now starts `sftp` and `git fetch` with standard input, output and error redirected to files in its staging folder (`Invoke-VigilFetchProcess -ErrorToFile`), so each failure ends at once with its reason. On the Windows test machine: sftp 34 of 34, and git 44 of 44.

Windows' OpenSSH under git hangs even on success, because git talks to it over pipes for the protocol itself. Git for Windows' own ssh, its default, works. That isn't Vigil's to fix; the sources report says so.
