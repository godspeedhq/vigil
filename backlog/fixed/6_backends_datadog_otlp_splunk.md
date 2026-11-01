# Metric backends beyond `file`

Datadog, OTLP, Splunk and the rest specified in spec 15, sent by the
sender with the spool's backoff. Credentials by reference only, sent with
curl (stdin) or .NET.

## Done when
- Each backend: conformance cases for the request it builds, integration
  test against a mock, both twins.

MVP: Datadog and OTLP first; the rest after the MVP.

## Status
Done for the MVP: `datadog` (Series API v2) and `otel` (OTLP/HTTP JSON),
with the `backend` conformance suite and `tests/integration/backends.sh`
and `Backends.ps1`. Splunk and the other types in spec 15.3 follow after
the MVP.
