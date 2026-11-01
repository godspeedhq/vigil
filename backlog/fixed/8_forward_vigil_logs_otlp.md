# Forwarding Vigil's own logs (OTLP)

`[log_forward]` and `[log_destination.*]` (spec 13.4): batch, cap, back off.

## Done when
- Integration test against a mock OTLP endpoint, both twins.

## Status
Done: `vigil_logs` (logs.sh, Logs.ps1), with the `logs` conformance suite and
`tests/integration/logs.sh` and `Logs.ps1` against a mock OTLP receiver.
Native `splunk` and `datadog` destinations follow after the MVP.
