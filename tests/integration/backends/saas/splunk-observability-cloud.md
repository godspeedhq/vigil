# Splunk Observability Cloud: manual setup for Vigil's tests

**Nobody but you creates this account.** Nothing in this repository registers, accepts terms, enters payment details or turns on a paid feature.

## Which Splunk is which

| Product | What it is | How Vigil is tested with it |
| --- | --- | --- |
| **Splunk Enterprise** | Self-hosted Splunk, with the HTTP Event Collector | Locally, in Docker: `compose.splunk.yaml` |
| **Splunk Cloud Platform** | Splunk Enterprise, hosted by Splunk, with HEC | The same `splunk` backend and log destination, with an `https://` endpoint. Not part of these tests. |
| **Splunk Observability Cloud** | A separate SaaS product for metrics, traces and RUM, formerly SignalFx | This guide |

Vigil's `splunk` backend and log destination speak HEC. Observability Cloud doesn't take HEC: it takes OTLP and its own ingest API. So the HEC tests run against local Splunk Enterprise, and Observability Cloud is tested with what it accepts.

## 1. Register for the Free Edition

- Free Edition: https://help.splunk.com/en/splunk-observability-cloud/get-started/free-edition/splunk-observability-cloud-free-edition
- Splunk: https://www.splunk.com/

Read the Free Edition page when you register. It sets who is eligible, how long it lasts, and what it includes. Record what you found in `reports/compatibility.md`. **Don't assume a feature is included because the paid product has it.**

## 2. What Vigil could send it

**Metrics:** Observability Cloud's ingest takes OTLP metrics at the realm's ingest endpoint, with an access token in an `X-SF-Token` header. Vigil's `otel` metrics backend sends its credential only as `Authorization: Bearer`, so whether it can send directly depends on whether the endpoint also accepts a bearer token. Check this at the first run, against Splunk's current documentation. If it doesn't, the route is a collector in between, an OpenTelemetry Collector with the `signalfx` or `otlphttp` exporter, which is an **integration through an intermediary**.

**Logs:** Observability Cloud forwards logs to Splunk Cloud Platform or Enterprise through Log Observer Connect; it doesn't store them itself. Treat logs as **not supported** here, and test them against Splunk Enterprise instead.

## 3. Create a dedicated access token

In Observability Cloud, go to **Settings, then Access Tokens**, and create an ingest token, for example `vigil-tests`. Use it for these tests only. Note your **realm** (such as `us1` or `eu0`), which is part of every endpoint.

Give the token to Vigil only as a reference (`env:SPLUNK_O11Y_TOKEN` or `secret:SPLUNK_O11Y_TOKEN`), never pasted into a configuration file.

## 4. What the tests will check

They run only once you've supplied the token:

- **Metrics:** the probe metric with this run's tag, found in the Metric Finder or with the metrics query API.
- **Authentication failure:** a wrong token is refused and reported, and never appears in a log.
- **Recovery:** with the endpoint blocked and then unblocked, the spooled metrics arrive afterwards.

Anything the Free Edition doesn't include is reported as **Blocked by licensing or account restrictions**.
