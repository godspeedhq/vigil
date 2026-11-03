# 24. Secrets management: a real test environment

Extend the real-backend test environment (`tests/integration/backends/`, task 18) with a ninth logical group, `compose.secrets.yaml`, that tests Vigil's existing secret stores against real self-hosted services and local cloud emulators.

## Principles

- Docker first, cloud only when necessary.
- Genuine implementations where they exist; emulators for cloud services where practical.
- Every service independently selectable through its own Compose profile; none starts by default.
- **No change to Vigil's production code, and no new store types,** to suit the tests. Only what Vigil already implements is tested.
- Dummy credentials and test secrets only. Nothing real, nothing committed.

## Services

| # | Service | Image or source | Profile |
| --- | --- | --- | --- |
| 1 | OpenBao | `openbao/openbao` | `openbao` |
| 2 | HashiCorp Vault | `hashicorp/vault` | `vault` |
| 3 | Floci AWS | `floci/floci` | `aws` |
| 4 | LocalStack | `localstack/localstack` | `aws-localstack` |
| 5 | Floci Azure | `floci/floci-az` | `azure` |
| 6 | Azure Key Vault emulator | a community Docker implementation | `azure-alt` |
| 7 | Floci GCP | `floci/floci-gcp` | `gcp` |
| 8 | GCP Secret Manager emulator | `ghcr.io/blackwell-systems/gcp-secret-manager-emulator-dual` | `gcp-alt` |

Before each is implemented:
- Verify that the image exists, is maintained, and supports the operations Vigil actually uses.
- Pin it to a tested version or digest.
- An image that is unavailable, incompatible, unmaintained or under an unsuitable licence is documented as such, not swapped for something unrelated.
- Check LocalStack's current licence and whether Secrets Manager is in its free tier before relying on it.

## What Vigil supports, so what can be tested

From spec 6.5.3. Whatever is outside this list is reported **Not supported**, never added:

- **`hashicorp_vault`** (Vault and OpenBao):
  - KV version 2 only, `GET {url}/v1/{mount}/data/{NAME}`, the latest version, one `field`
  - `auth = token` or `approle`
  - KV v1 and choosing a version are not supported
- **`aws_secrets_manager`:**
  - `GetSecretValue` over https to `endpoint` (scheme and host), signed with SigV4
  - `access_keys` (testable) or `instance_profile` (IMDS at 169.254.169.254: not testable locally)
  - an optional JSON `field`
- **`azure_keyvault`:**
  - `GET {vault}/secrets/{NAME}[/<version>]?api-version=7.4`
  - signed in by `service_principal` at `{authority}/{tenant}/oauth2/v2.0/token` (testable if the emulator issues tokens), or `managed_identity` (IMDS: not testable locally)
- **`gcp_secret_manager`:**
  - `GET {endpoint}/v1/projects/{project}/secrets/{NAME}/versions/{version}:access`, a number or `latest`
  - signed in by `service_account_key` at its `token_uri`, which must be https (testable if something local issues tokens), or `metadata` (not testable locally)
- **Every store is https only, with certificate verification.** An emulator serving plain http needs TLS in front of it, from a test CA given to Vigil as `ca_file`. That is test infrastructure, not a change to Vigil.
- **Secrets are fetched fresh at every run and never cached,** so "rotation" means a changed value is used by the next run. There is no renewal or fallback to test.
- Creating and updating secrets is the test fixtures' job, done with each service's own CLI or API. Vigil only reads.

## Tests, for each store that applies

- an existing secret delivered to a Vigil job (checked by its hash, never shown)
- a missing secret
- an invalid credential
- permission denied
- an expired credential, where the service issues expiring ones
- an update, used by the next run
- choosing a version, where Vigil supports it
- the service down, then restarted, and Vigil recovering at its next run
- the secret's value absent from Vigil's logs, state, spool and telemetry
- credentials absent from every error message

Emulator results never count as proof of the real cloud's authentication (IAM, Microsoft Entra ID, managed identity, workload identity). Each cloud gets a separate, optional, manual test against the real service, documented and never provisioned for you.

## Layout

```
tests/integration/backends/
  compose.yaml               includes compose.secrets.yaml
  compose.secrets.yaml       group 9
  configs/secrets/{openbao,vault,aws,azure,gcp}/
  scripts/start.sh stop.sh reset.sh  the same commands as every other target
  scripts/run-store.sh run-store.ps1 the store tests
  reports/secrets-compatibility.md
```

## Compose requirements

- One profile per service, and none started by default. The eight observability groups are unchanged.
- Ports on 127.0.0.1 only, clear of every observability port.
- Images pinned. Each service has a health check, and a named volume where it keeps data.
- Deterministic fixtures, from a provisioning script per service. Dummy credentials only.
- Start, stop and reset through the existing scripts.
- Runs on Docker on Linux, macOS and Windows, with Vigil on all three.
- CPU and memory documented.

## Report

`reports/secrets-compatibility.md`: backend, deployment, API compatibility, authentication, retrieval, rotation, result.

- **Results:** Passed, Failed, Not supported, Not applicable, Not tested, Emulator limitation, or Blocked by licensing.
- **Kinds of validation,** kept apart: real backend, emulator, and real cloud.

## Phases

1. **Vault-compatible:**
   - OpenBao, then HashiCorp Vault, with the same fixtures and tests
   - server mode with persistent storage and a stable test CA, so a restart can be tested
   - differences between the two recorded, never assumed away
2. **Cloud emulators:** AWS (Floci, LocalStack), Azure (Floci, a community emulator), GCP (Floci, the community emulator), each checked against the requests above before it is accepted.
3. **Failure and recovery:** shutdown, restart, invalid and expired credentials, missing secrets, permission denial, updates.
4. **Report:** what is validated, and what still needs the real cloud.

## Progress

- **Before this task** (PR #65): OpenBao in dev mode, with `run-store.sh` and `run-store.ps1`. Covered so far: AppRole, a token, missing (404), permission denied (403), an untrusted certificate, and no value written. 11 of 11 on Linux, macOS and Windows.
- **Phase 1: done (2026-11-03).** OpenBao 2.7.1 and Vault 2.2.0 run in server mode on integrated storage (raft), with TLS from a test CA. Both use the same fixtures and the same tests.
  - **Fedora 44:** 26 of 26 on each, restart included.
  - **macOS 12.7.6 and Windows 11:** 22 of 22 on each, through tunnels; restart reported NOT RUN, since it needs the Docker host.
  - **No differences** between the two in what Vigil uses.
  - **KV v1** is shown to be unreadable by Vigil, as it is: reported Not supported, not changed.
  - Report: `reports/secrets-compatibility.md`.
- **Phase 3, to come:** run the restart checks from macOS and Windows too, stopping and starting the Docker host's container remotely.
- **Phase 2:** next, starting with checking each emulator image.
