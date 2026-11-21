# 65. Every vigil command on Windows took seconds to start

Found on 2026-11-20: `vigil pack search` was slow on Windows, and slowest
on a Windows 11 laptop with Malwarebytes, where even `vigil version` took
seconds.

## Why

`vigil.ps1` loaded all 26 of its libraries (575 KB of PowerShell) for every
command. PowerShell hands each script it loads to the machine's antivirus
(AMSI) before running it. On that laptop the antivirus took 7.5 seconds over
the 26, against 0.16 seconds to parse them. A machine with a slower
antivirus, or a busier one, waits longer.

Workers had the fix already (backlog 52): a worker loads only the libraries
its kind of run can use (`$workerLibs`). Commands did not.

`pack search`, `info`, `list --available` and `install` also downloaded the
newest release's index and its signature every time, even when the index
saved in `packs/.index` (since 1.2.0) was of that same release.

## The fix

- **Each command loads only the libraries it can use** (`$commandLibs` in
  `vigil.ps1`), in the order of the full list. A command not in it loads them
  all.
- **`tests/Test-WorkerLibraries.ps1` checks the lists against the code,** as
  it does the workers': from each command's branch of `vigil.ps1`'s switch,
  and the code every command runs before it, it follows every function
  called and every `$Script:` variable read, through all branches, and fails
  on a library the list leaves out, or a command with no list.
- **The saved index is read when it is the newest release's,** and its
  signature checks: only the latest release's name is asked for, not the
  index and its signature again. A published release's index does not
  change. On Linux and macOS too.

## Done

- `tests/Test-WorkerLibraries.ps1`: 24 passed, 0 failed (5 kinds of worker,
  19 commands), under Windows PowerShell 5.1 and PowerShell 7.
- `tests/integration/Pack.ps1`: 114 passed, 0 failed, under both;
  `tests/integration/pack.sh` on Fedora: 115 passed, 0 failed. Each has a new
  check: with the index gone from the newest release, `pack search` still
  answers from the one saved here, and says nothing of a failure.
- Timed against `main`, started as `vigil.cmd` starts it, the median of three
  runs, in seconds (2026-11-21):

  | Command | Windows 11 (Defender), 5.1 | the same, 7 | Server 2025 (Defender), 5.1 |
  | --- | --- | --- | --- |
  | `version` | 1.7 → 1.3 | 3.3 → 1.1 | 1.3 → 0.8 |
  | `pack search` | 3.7 → 2.5 | 1.9 → 1.4 | 3.3 → 2.4 |
  | `pack list` | 3.4 → 2.9 | 0.9 → 0.8 | 1.3 → 1.0 |
  | `secret list` | 1.5 → 1.3 | 1.0 → 0.7 | 1.7 → 0.7 |
  | `status` | 1.9 → 1.8 | 1.0 → 0.8 | 1.7 → 1.2 |

  PowerShell alone took 0.3 to 0.8 seconds to start, and asking GitHub for
  the newest release about a second: no change to Vigil removes those. On
  the laptop with Malwarebytes, `pack search` still takes 7 to 8 seconds, 3.3
  of them for its libraries.

## Not done

- Splitting `Pack.ps1`, so `search` and `info` load less: a guessed half a
  second, for more files and lists to keep right.
- Remembering the newest release for a while: a pack released meanwhile
  would not be found (backlog 63 chose otherwise).
- Running `vigil.cmd` under PowerShell 7 where installed: faster, but which
  PowerShell runs would then depend on the machine (see backlog 62).
