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
  configs/platforms/         the observability groups' configuration
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

- **Phase 2: started (2026-11-03).**
  - **Floci AWS 2.3.0: done.** It sits behind an nginx TLS front (1.30.5-alpine) with the test CA. 20 of 20 on Fedora with the restart; 18 of 18 on macOS and Windows. One emulator limitation everywhere: any secret key is accepted.
  - **The images, as checked:**

    | Service | Pin | Licence | What Vigil needs from it |
    | --- | --- | --- | --- |
    | `floci/floci` | 2.3.0 | MIT | done, as above |
    | `floci/floci-az` | 0.15.0 | MIT | Key Vault secrets with versions; an emulated Entra ID issuing `client_credentials` tokens, so `service_principal` may sign in for real; TLS via `FLOCI_AZ_TLS_ENABLED`, or the nginx front |
    | `floci/floci-gcp` | 0.11.0 | MIT | Secret Manager over REST, http only (front needed); IAM checks with `FLOCI_GCP_SERVICES_IAM_AUTHORIZATION_MODE=enforce`. Unknown yet: whether anything answers the JWT-bearer grant Vigil sends to `token_uri` |
    | `localstack/localstack` | 2026.10.0 | free tier with an account | **blocked:** since 2026.03.0 it needs `LOCALSTACK_AUTH_TOKEN` from a LocalStack account. Testable only if the user supplies a token in `.env` |
    | Azure community emulator | Lowkey Vault (`nagyesta/lowkey-vault`, MIT), the best fit | MIT | api-version 7.4 over https, choosing versions. No client-credentials token endpoint, only a managed-identity one; Vigil's `managed_identity` always goes to 169.254.169.254, so sign-in there is an emulator limitation, unless Vigil's existing test switch `VIGIL_TEST_IMDS` is used and labelled as such |
    | `ghcr.io/blackwell-systems/gcp-secret-manager-emulator-dual` | no release published yet: pin by digest | Apache 2.0 | REST on 8080, which collides with SigNoz, so published elsewhere; no authentication; http only (front needed) |

  - **Floci Azure 0.15.0: done.** `service_principal` signs in for real at the emulated Entra ID, and `managed_identity` is exercised through `VIGIL_TEST_IMDS`. Chosen versions are fetched. 22 of 22 on Fedora; 20 of 20 on macOS and Windows. One emulator limitation everywhere: any client secret is accepted, and so is any token.
  - **Floci GCP 0.11.0: done.** `service_account_key` signs its JWT with a real RSA test key and exchanges it at the emulator's `/token` (the key's `token_uri`). Numbered versions and projects are kept apart, and a plain-http `token_uri` is refused. 22 of 22 on Fedora; 20 of 20 on macOS and Windows. One emulator limitation everywhere: any JWT is accepted. `metadata` is untested: there is no metadata server.
  - **Lowkey Vault 7.3.127: done.** It serves TLS itself with the test certificate (it tells vaults apart by Host and port). Its stores sign in with `managed_identity` through `VIGIL_TEST_IMDS`, since it has no client-credentials endpoint; `service_principal` is an emulator limitation. 22 of 22 on Fedora; 20 of 20 on macOS and Windows.
  - **Real-cloud guides** (phase 4), optional and manual, never provisioned for you: `saas/aws-secrets-manager.md`, `saas/azure-key-vault.md`, `saas/google-secret-manager.md`.
  - **Blackwell's emulator 1.9.0: done**, pinned by digest. It has no sign-in at all, so Vigil signs in at Floci GCP's `/token` and reads from Blackwell: retrieval only. 22 of 22 on Fedora; 20 of 20 on macOS and Windows.
- **Phase 2: done, but for LocalStack** (blocked by licensing; testable if you supply a token in `.env`).
- **Phase 3, next:** the restart checks from macOS and Windows, stopping and starting the Docker host's containers remotely.
