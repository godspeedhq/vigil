# Release v0.2.1

The first real update, for testing `vigil self update` on real machines:
`vigil about`, `max_file_mb`, no size limit on fetched scripts, and
`install --update-by`.

## Done when
- Tested on real Linux, macOS and Windows machines, updating from v0.2.0.
- The release is a draft until its notes are reviewed and it is approved.

## Done

- Published on 2026-11-02, after its notes were reviewed.
- Tested on the real Fedora 44, macOS 12 and Windows 11 machines on 2026-11-04, with `tests/integration/backends/scripts/run-update.sh` and `run-update.ps1`: the real v0.2.0, installed from GitHub, updated itself to the latest release (v0.2.2, which carries 0.2.1's changes) with jobs running across it; and v0.2.1, the first signed release, did the same, its signature verified with the key 0.2.1 carries. 18 of 18 and 19 of 19 on each machine. Results and evidence in `tests/integration/backends/reports/updates.md`.
