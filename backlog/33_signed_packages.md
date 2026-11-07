# 33. Packages that need a code-signing certificate (on hold)

On hold (owner, 2026-11-07): any package manager that needs signing, or a
certificate bought for it, waits until code signing is taken up (backlog
12). Split out of backlog 30, which ends with MacPorts.

| Format | Installs with | Needs |
| --- | --- | --- |
| MSI built with WiX, for Intune, Group Policy and SCCM | `msiexec /i vigil-….msi /qn` | the code-signing certificate (backlog 12) |
| winget, from the MSI | `winget install GodspeedHQ.Vigil` | the MSI |

Not NSIS (an `.exe` wizard): companies ask for an MSI, and winget takes the
MSI. The macOS `.pkg` is not needed: MacPorts covers macOS (not_needed/34).

## What the code already has

The groundwork from backlog 30 step 0 holds for an MSI as it does for Scoop:
a read-only program with an `app\PACKAGED` file naming the manager, the
upgrade command, the root and the service, so `vigil self update` and
`vigil service install` and `remove` refuse and name the MSI's way.

## Done when

- Backlog 12 gives a certificate usable from CI.
- A signed MSI installs, upgrades and removes Vigil silently on a clean
  Windows host, with the service registered and started.
- winget installs the MSI.
