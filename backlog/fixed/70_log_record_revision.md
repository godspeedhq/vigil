# A forwarded log line carried the revision it was sent under

Found by the fleet test (bug B1 in `tests/integration/backends/reports/runs/2026-11-26/fleet-run2/BUGS.md`) on 2026-11-26: around a configuration change, forwarded log lines carried the wrong configuration, in both directions. Lines written before the change carried the new revision and tags, and the line `configuration revision X loaded` itself often carried the revision before X: 21 times in the second run, so a query by the `wave` tag found 19 of 24 activations.

## What was wrong

Every record carries the host, the tags and the configuration revision (§13.4.2). The forwarder took the revision and tags active when it ran, and gave them to every line it sent then. It runs on its own schedule, often behind the logs, so the lines around a change went with whichever configuration was active when they were sent. Those are the minutes someone reads the logs to judge a change by.

## The fix

- **The supervisor keeps a history.** Each time it activates a revision, local or fetched, it appends `<epoch> <revision> <tags>` to `state/config.history`: one line per change of revision or tags, the last 50.
- **The forwarder reads it.** Each line goes with the last revision activated at or before the line's own time, and that revision's tags. A line older than the history gets the first recorded; a line with no time keeps the revision of the line before it. Lines come mostly in order, so the search starts from the previous line's.
- **A request carries one revision**, since OTLP puts it on the request's resource: a batch ends where the revision changes.
- **Without a history** (just after an upgrade), the active revision is used, as before.
- Both twins. The configuration's own tags are built by one function each (`vigil_config_tagline`, `Get-VigilConfigTagLine`) for the history and the forwarder alike.

Times are whole seconds: a line written in the same second as an activation, by a run started under the configuration before, goes with the new one.

## Tests

`tests/integration/logs.sh` and `Logs.ps1`: a line written under `wave = first`, held back by an outage, then the tag changed to `second` and another line written; when the destination recovers, each line arrives in its own request with its own tags and revision. On `main` the check fails (both lines in one request, with the second revision); with the fix it passes.

## Closed

2026-11-27.
