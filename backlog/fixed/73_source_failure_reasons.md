# A refused configuration and an unreachable source looked the same in metrics

Found by the fleet test on 2026-11-26 (bug B4 in `tests/integration/backends/reports/runs/2026-11-26/fleet-run2/BUGS.md`). In wave 4 a configuration with an unknown section was published. The fleet's dashboard showed it as fetch failures, as it showed Gitea being down. `vigil_supervisor_config_reload_failed` stayed 0. Only the log told them apart: `line 93: unknown section [fleet_nonsense] (E_SECTION_UNKNOWN)`.

## What was wrong

Nothing in Vigil. `vigil.source.failures` is tagged by `reason` (§14.5): `unreachable`, `timeout`, `auth`, `digest` or `invalid`, and a fetched configuration that does not validate is `invalid`. The fleet test's dashboard summed the counter without the tag. `config_reload_failed` is about the local file, so it stays 0 for a fetched configuration that is refused, and the running one carries on.

What was missing was proof: the suites checked only `reason="digest"`.

## The fix

- **Tests:** `tests/integration/fetch.sh` and `Fetch.ps1` check `reason="unreachable"` for a source that cannot be reached, and `reason="invalid"` (and no `unreachable`) for a fetched configuration that is refused.
- **The fleet test's dashboard** splits the counter by reason (branch `fleet-test`).

## Closed

2026-11-28.
