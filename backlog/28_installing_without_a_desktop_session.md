# 28. Installing without a desktop session

## Why

Installing `0.2.3-dev.f1ef2a1` (main at #69) in user mode over SSH, on the
test machines, as `vigil-test`:

| System | Result |
| --- | --- |
| Fedora 44 | Installed, and running under `systemd --user`. The installer says it runs only while the user is logged in, and how to change that (`loginctl enable-linger`). Correct. |
| macOS 12.7 | Installed; the LaunchAgent is written, but `launchctl bootstrap gui/503` fails (error 125), since an SSH login has no GUI session. The installer then said "fix what the checks above report", though every check passed. |
| Windows 11 | Installed; the Run entry is registered. Starting the supervisor went through `Win32_Process.Create` (WMI), which is refused under a network logon (backlog 23), so it failed, and the installer then threw "the service was not registered", which was wrong: it was. `vigil` could not run from PowerShell where the execution policy is Restricted, the default on client Windows: PowerShell runs `app\vigil.ps1` ahead of `vigil.cmd` beside it, and the policy refuses it. |

A server reached only over SSH is the normal case, not an edge case.

## Done

- **Windows, starting the supervisor:** `Start-VigilDetached` (Worker.ps1)
  starts it through WMI or, where WMI refuses, with `CreateProcess` out of
  the session's job. Windows' sshd puts a session in a job that ends every
  process in it at logout and allows breakaway (flags `0x2800`); a process
  started this way was proven to outlive the SSH session. On the Windows
  test machine an SSH install now starts Vigil, and the next SSH login finds
  it running. `vigil uninstall`'s detached cleanup uses the same.
- **Windows, the command:** `vigil.cmd` moved to `app\bin`, which is on the
  PATH in place of `app\` (a reinstall moves an earlier entry), so
  PowerShell finds it and it runs `vigil.ps1` with the policy bypassed for
  that one process. `Install.ps1` checks `vigil` under `-ExecutionPolicy
  Restricted`, and the move of the PATH entry.
- **The messages:** macOS says it could not start because the login has no
  desktop session, that it starts at the next desktop login, and what to do
  until then; both installers give the reason above instead of "fix what
  the checks above report"; Windows says "started", not "restarted", when
  nothing was running.

## Still open

- **macOS without a desktop session:** a LaunchAgent can be bootstrapped
  into the user's background domain (`launchctl bootstrap user/<uid>`) from
  SSH when its plist says `LimitLoadToSessionType = Background`; proven on
  the Mac to outlive the SSH session. But nothing loads it again after a
  reboot, the same plist with that type does not load at a desktop login,
  and a desktop login could then start a second supervisor. Until that is
  designed, a headless Mac takes `--system` (a LaunchDaemon).
- **Tests:** install over SSH on the three test machines as part of the
  real-system runs, with the output kept as evidence.

## Done when

- On all three, an SSH install either runs Vigil or says exactly why not and
  what to do, and `vigil status` works in the next SSH login.
