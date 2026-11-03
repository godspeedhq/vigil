# Datadog: manual setup for Vigil's tests

Datadog has no self-hosted equivalent, so Vigil's `datadog` metrics backend and `datadog` log destination are tested against a real Datadog account. **Nobody but you creates that account.** Nothing in this repository registers, accepts terms, enters payment details or turns on a paid feature.

## 1. Register

- Free trial: https://www.datadoghq.com/free-datadog-trial/
- Pricing and the free tier: https://www.datadoghq.com/pricing/

Check both pages when you register, since the terms change:
- **The trial:** 14 days of most features, with no card needed at the time of writing.
- **After the trial:** the account can drop to the free tier, which keeps a limited number of hosts and a short metric retention. **Log management is a paid feature,** so log tests may only work during the trial.

## 2. Choose the site

Datadog accounts live on one site, chosen at registration. Vigil's endpoints must match:

| Site | Metrics (`[backend.*] endpoint`) | Logs (`[log_destination.*] endpoint`) |
| --- | --- | --- |
| US1 | `https://api.datadoghq.com` | `https://http-intake.logs.datadoghq.com` |
| EU1 | `https://api.datadoghq.eu` | `https://http-intake.logs.datadoghq.eu` |
| US3 | `https://api.us3.datadoghq.com` | `https://http-intake.logs.us3.datadoghq.com` |
| US5 | `https://api.us5.datadoghq.com` | `https://http-intake.logs.us5.datadoghq.com` |
| AP1 | `https://api.ap1.datadoghq.com` | `https://http-intake.logs.ap1.datadoghq.com` |

## 3. Create a dedicated API key

In Datadog, go to **Organization Settings, then API Keys, then New Key**, named for example `vigil-tests`. Use it for these tests and nothing else, and revoke it when they're done.

Give it to Vigil only as a reference. Never paste it into a configuration file:

```sh
export DD_API_KEY=...                         # this shell only
# or, kept by Vigil, encrypted on Windows:
printf '%s' "$DD_API_KEY" | vigil secret set DD_API_KEY --stdin
```

```ini
[backend.datadog]
type     = datadog
endpoint = https://api.datadoghq.eu
api_key  = env:DD_API_KEY

[log_forward]
destination = datadog
include     = supervisor, run, stdout, stderr

[log_destination.datadog]
type     = datadog
endpoint = https://http-intake.logs.datadoghq.eu
api_key  = env:DD_API_KEY
```

## 4. What the tests will check

They're prepared, and run only once you've supplied the key:

- **Metrics:** the probe metric `bk_metrics.vigil_backend_probe` with this run's tag, found with the Metrics Explorer or the query API (`GET /api/v1/query`, which needs an application key as well as the API key).
- **Logs:** a line with this run's tag, found in Log Explorer or with the logs search API.
- **Authentication failure:** a wrong key is refused and reported, never retried for ever, and the key never appears in a log.
- **Recovery:** with the endpoint blocked and then unblocked, the spooled metrics arrive afterwards.

## 5. What needs payment

To check against Datadog's pricing page when the tests run, and record in `reports/compatibility.md`:

- Log management after the trial.
- Longer metric retention.
- More than the free tier's host count.

Anything a test needs that only a paid plan offers is reported as **Blocked by licensing or account restrictions**, not as failed.
