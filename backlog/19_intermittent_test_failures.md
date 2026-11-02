# Intermittent test failures

Each has failed once or twice and passed on rerun. Any of them may be a real
race in Vigil, not only a slow runner, so none should be written off as noise.
The tests now print what they know when these fail.

- `tests/integration/upgrade.sh`, macOS: `scheduled jobs carry on`, on the
  merge of #41. A job did not run three more times within 60 seconds of the
  update.
- `tests/integration/Service.ps1`, PowerShell 7: `user/pwsh: start succeeds`,
  on #43. `vigil start` exited 1 and the service stayed inactive.
- `tests/integration/self-update.sh`, macOS: `reload: it says so`.
- `tests/integration/Self-Update.ps1`, Windows, run locally:
  `reload: the supervisor is running`.

None came back in 24 macOS upgrades and self updates, or 12 Windows service
runs, with diagnostics on.

## Done when
- Each has a known cause and is fixed, or is shown to be the test's timing.
