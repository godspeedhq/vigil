# Windows: self update without admin rights

`install --update-by` gives Linux and macOS a narrow sudo rule. Windows has
no equivalent, so a system install still needs an elevated prompt.

## Scope
- A small privileged updater, installed once. Ordinary accounts may only ask
  it to move to the latest release.
- Needs `11` first: it installs from the internet with admin rights.

## Done when
- A non-admin account updates a Windows system install, and cannot choose a
  version or run anything else as admin.
