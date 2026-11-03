# Secrets compatibility matrix

How Vigil's secret stores work with real secret services and local emulators, and what a real test showed (backlog task 24). A result changes only with evidence from a run of `scripts/run-store.sh` or `run-store.ps1`. A test that didn't run is never marked Passed.

**Three kinds of validation, never mixed:**
- **Real backend:** the genuine product, run locally (OpenBao, HashiCorp Vault).
- **Emulator:** a local stand-in for a cloud API. It shows Vigil's requests and its handling of answers. It proves **nothing** about the real cloud's sign-in (IAM, Microsoft Entra ID, managed identity, workload identity).
- **Real cloud:** the provider's own service, with credentials you supply. Optional and manual; never provisioned for you.

**Results:** Passed, Failed, Not supported (by Vigil), Not applicable, Not tested, Emulator limitation, Blocked by licensing.

## Matrix

| Backend | Deployment | Validation | API compatibility | Authentication | Secret retrieval | Rotation | Result |
| --- | --- | --- | --- | --- | --- | --- | --- |
| OpenBao (`openbao/openbao:2.7.1`) | Docker, server mode, raft, TLS | Real backend | **Passed**: KV v2 reads, as Vigil's `hashicorp_vault` | **Passed**: token, AppRole; bad, expired and wrong-policy credentials refused | **Passed**: KV v2. KV v1: **Not supported** by Vigil | **Passed** | **Passed** |
| HashiCorp Vault (`hashicorp/vault:2.2.0`) | Docker, server mode, raft, TLS | Real backend | **Passed**, the same | **Passed**, the same | **Passed**: KV v2. KV v1: **Not supported** by Vigil | **Passed** | **Passed** |
| Floci AWS (`floci/floci:2.3.0`) | Docker, behind an nginx TLS front | Emulator | **Passed**: `GetSecretValue` as Vigil's `aws_secrets_manager` signs it; regions kept apart | **Emulator limitation**: any key is accepted, signatures are not checked | **Passed**, with `field`; binary secrets: **Not supported** by Vigil | **Passed** | **Passed**, as an emulator (see limits below) |
| LocalStack (`localstack/localstack`) | Docker | Emulator | Not tested | Not tested | Not tested | Not tested | **Blocked by licensing**: since 2026.03.0 it won't start without a LocalStack account's auth token, and no account is made for you |
| Floci Azure (`floci/floci-az:0.15.0`) | Docker, behind an nginx TLS front | Emulator | **Passed**: Key Vault `GET .../secrets/{name}[/{version}]?api-version=7.4`, as Vigil's `azure_keyvault` asks | **Passed** as requests: `service_principal` signs in at the emulated Entra ID; `managed_identity` through Vigil's test switch. **Emulator limitation**: any client secret and any token are accepted | **Passed**, the latest and a chosen version | **Passed** | **Passed**, as an emulator (see limits below) |
| Azure Key Vault emulator (community) | Docker | Emulator | Not tested | Not tested | Not tested | Not tested | Not tested (phase 2) |
| Floci GCP (`floci/floci-gcp:0.11.0`) | Docker, behind an nginx TLS front | Emulator | **Passed**: `GET .../secrets/{name}/versions/{version}:access`, as Vigil's `gcp_secret_manager` asks; projects kept apart | **Passed** as requests: `service_account_key` signs its JWT and exchanges it at the key's `token_uri`. **Emulator limitation**: any JWT is accepted. `metadata`: **Not tested**, no metadata server | **Passed**, the latest and a numbered version | **Passed** | **Passed**, as an emulator (see limits below) |
| GCP Secret Manager emulator (community) | Docker | Emulator | Not tested | Not tested | Not tested | Not tested | Not tested (phase 2) |
| AWS Secrets Manager | Real cloud | Real cloud | Not tested | Not tested | Not tested | Not tested | Not tested |
| Azure Key Vault | Real cloud | Real cloud | Not tested | Not tested | Not tested | Not tested | Not tested |
| Google Secret Manager | Real cloud | Real cloud | Not tested | Not tested | Not tested | Not tested | Not tested |

## OpenBao and Vault: what was tested

Each check ran against both servers, configured alike, with the same fixtures (`configs/secrets/provision.sh`).

| Check | Vigil's store reached with | Must end, at precheck and at the run | OpenBao | Vault |
| --- | --- | --- | --- | --- |
| Retrieval, delivered to a job | AppRole | succeeded; the job's secret hashes to the fixture's SHA-256 | Passed | Passed |
| Retrieval | a token | succeeded, the same way | Passed | Passed |
| Missing secret | AppRole | `not found (HTTP 404)` | Passed | Passed |
| Permission denied | AppRole, a path its policy doesn't allow | `permission denied (HTTP 403)` | Passed | Passed |
| Untrusted certificate | a token, no `ca_file` | `the certificate of 127.0.0.1:<port> is not trusted` | Passed | Passed |
| Invalid token | a random token | `permission denied (HTTP 403)` | Passed | Passed |
| Expired token | a 5-second token, after it expired | `permission denied (HTTP 403)` | Passed | Passed |
| Invalid AppRole secret id | a random secret id | `sign-in failed: HTTP 400 from 127.0.0.1:<port>` | Passed | Passed |
| KV v1 | a token, `mount = kv1` | `not found (HTTP 404)`: Vigil reads only KV v2 paths (`kv1/data/...`), though `kv1/vigil/probe` exists and the token may read all of `kv1/` | Passed (as **Not supported**) | Passed (as **Not supported**) |
| Rotation | AppRole | after the secret is given a new value, the next run gets it, with nothing restarted | Passed | Passed |
| Store stopped | a token | `cannot connect to 127.0.0.1:<port>` | Passed | Passed |
| Store restarted, still sealed | a token | `HTTP 503 from 127.0.0.1:<port>` | Passed | Passed |
| Recovery, once unsealed | a token, then AppRole | succeeded, with the same credentials | Passed | Passed |
| No secret or credential written down | all | none of 11 values (secrets, tokens, secret ids, wrong ones too) under the Vigil root (logs, state, spool, telemetry) or in anything Vigil printed | Passed | Passed |

**Differences found between OpenBao and Vault:** none in what Vigil uses. Both answer a wrong AppRole secret id with HTTP 400, not 403. One difference outside Vigil: OpenBao 2 has no `file` storage, so both run integrated storage (raft) here.

**What isn't tested, because Vigil doesn't do it** (spec 6.5.3):
- KV v1
- choosing a secret version
- token renewal
- caching

Secrets are fetched fresh at every run, so there is nothing to renew or invalidate.

## AWS Secrets Manager, through Floci: what was tested

Vigil's `aws_secrets_manager` store, `client = http`, `auth = access_keys` with dummy keys, `endpoint = https://127.0.0.1:4566`. Floci speaks plain http, so an nginx in front of it serves https with the test CA. The fixtures come from `configs/secrets/aws/provision.sh`, which writes them again after every start, since Floci keeps everything in memory.

| Check | Must end, at precheck and at the run | Result |
| --- | --- | --- |
| Retrieval, delivered to a job | succeeded; the job's secret hashes to the fixture's | Passed |
| One key of a JSON secret (`field = password`) | succeeded, the same way | Passed |
| Missing secret | `not found (ResourceNotFoundException)` | Passed |
| A `field` the JSON lacks | `the secret's value: no nosuch` | Passed |
| A binary secret | `unexpected answer: no SecretString`: Vigil reads `SecretString` only | Passed (as **Not supported**) |
| The same name in another region (eu-west-2) | `not found (ResourceNotFoundException)`: regions are kept apart | Passed |
| Untrusted certificate (no `ca_file`) | `the certificate of 127.0.0.1:4566 is not trusted` | Passed |
| Rotation (`PutSecretValue`) | the next run gets the new value | Passed |
| A wrong secret key | real AWS: `permission denied (InvalidSignatureException)`. Floci: accepted | **Emulator limitation** |
| Emulator stopped | `cannot connect to 127.0.0.1:4566` | Passed (Fedora) |
| Emulator started again, fixtures rewritten | succeeded | Passed (Fedora) |
| No secret or credential written down | none of the values or keys under the Vigil root or in its output | Passed |

**What this does not show:**
- AWS's own sign-in. Signature checking, IAM policies, `AccessDeniedException` and `instance_profile` (IMDS) are all untested, because Floci accepts any key and has no instance metadata.
- Malformed requests. Vigil only ever sends a well-formed `GetSecretValue`; Floci's answer to bad JSON (`SerializationException`, HTTP 400) was checked by hand.
- Prove AWS itself with the optional real-cloud test.

## Azure Key Vault, through Floci: what was tested

Vigil's `azure_keyvault` store, `client = http`:
- `vault = https://127.0.0.1:4577/vigiltest-keyvault`
- `auth = service_principal`, with `authority = https://127.0.0.1:4577`, the emulated tenant, and a dummy client id and secret

Floci speaks plain http, so an nginx in front serves https with the test CA for Key Vault and the token endpoint alike. The fixtures come from `configs/secrets/azure/provision.sh`, written again after every start.

| Check | Must end, at precheck and at the run | Result |
| --- | --- | --- |
| Sign-in (`client_credentials` at `{authority}/{tenant}/oauth2/v2.0/token`) and retrieval, delivered to a job | succeeded; the job's secret hashes to the fixture's | Passed |
| The latest of two versions | succeeded, with the second value | Passed |
| A chosen version (`name/<version id>`) | succeeded, with the first value | Passed |
| Missing secret | `not found (HTTP 404)` | Passed |
| A version that doesn't exist | `not found (HTTP 404)` | Passed |
| A name Key Vault doesn't allow (`vigil_probe`) | `not a valid Key Vault secret name`, without a request | Passed |
| Untrusted certificate (no `ca_file`) | `sign-in failed: the certificate of 127.0.0.1:4577 is not trusted` | Passed |
| `managed_identity`, its token from `http://127.0.0.1:4578` through Vigil's test switch `VIGIL_TEST_IMDS` (spec 22.4.2), not 169.254.169.254 | succeeded | Passed, as a request (see below) |
| Rotation (a new version) | the next run gets the new value | Passed |
| A wrong client secret | real Entra ID: refused at sign-in. Floci: accepted | **Emulator limitation** |
| Emulator stopped | `sign-in failed: cannot connect to 127.0.0.1:4577` | Passed (Fedora) |
| Emulator started again, fixtures rewritten | succeeded | Passed (Fedora) |
| No secret or credential written down | none of the values or the client secret under the Vigil root or in its output | Passed |

**What this does not show:**
- Microsoft Entra ID's real sign-in. Floci accepts any client secret, and Key Vault accepts any bearer token, so a refused, expired or wrong-audience token is untested.
- A real managed identity. Only Vigil's request to the endpoint was exercised, through the test switch; Azure's own instance metadata service wasn't involved.
- Access policies and RBAC.
- Prove Azure itself with the optional real-cloud test.

## Google Secret Manager, through Floci: what was tested

Vigil's `gcp_secret_manager` store, `client = http`:
- `endpoint = https://127.0.0.1:4588`
- `auth = service_account_key`, with a key file in Google's format whose `token_uri` is `https://127.0.0.1:4588/token`, the emulator's OAuth2 endpoint

The keys hold real RSA test keys, so Vigil signs its JWT (RS256) just as it would for Google. Floci speaks plain http, so an nginx in front serves https with the test CA. The fixtures and keys come from `configs/secrets/gcp/provision.sh`.

| Check | Must end, at precheck and at the run | Result |
| --- | --- | --- |
| Sign-in (a signed JWT exchanged at `token_uri`) and retrieval, delivered to a job | succeeded; the job's secret hashes to the fixture's | Passed |
| The latest version | succeeded, with the newest value | Passed |
| A numbered version | succeeded, with that version's value | Passed |
| Missing secret | `not found (HTTP 404)` | Passed |
| A version that doesn't exist | `not found (HTTP 404)` | Passed |
| The same name in another project | `not found (HTTP 404)`: projects are kept apart | Passed |
| A key whose `token_uri` is plain http | `service_account_key env:...: its token_uri is not https`, without a request | Passed |
| Untrusted certificate (no `ca_file`) | `sign-in failed: the certificate of 127.0.0.1:4588 is not trusted` | Passed |
| Rotation (a new version) | the next run gets the new value | Passed |
| A key with another private key | real Google: refused at sign-in. Floci: accepted | **Emulator limitation** |
| Emulator stopped | `sign-in failed: cannot connect to 127.0.0.1:4588` | Passed (Fedora) |
| Emulator started again, fixtures rewritten | succeeded | Passed (Fedora) |
| No secret or private key written down | none of the values, nor a line of either private key, under the Vigil root or in its output | Passed |

**What this does not show:**
- Google's real sign-in. The JWT isn't verified, so a wrong key, a disabled service account or a missing IAM role is untested. Floci can check IAM (`FLOCI_GCP_SERVICES_IAM_AUTHORIZATION_MODE=enforce`), but only with tokens it issued for its own service accounts, which Vigil's key-file sign-in doesn't use.
- `auth = metadata`, since Floci has no metadata server.
- Prove Google itself with the optional real-cloud test.

## Runs

| Date | Vigil on | OpenBao | Vault | Floci AWS | Floci Azure | Floci GCP | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-11-03 | Fedora 44 (the Docker host), bash 5.3 | 26 of 26 | 26 of 26 | 20 of 20, 1 limitation | 22 of 22, 1 limitation | 22 of 22, 1 limitation | restart and recovery included |
| 2026-11-03 | macOS 12.7.6, bash 3.2, through SSH tunnels | 22 of 22, 1 not run | 22 of 22, 1 not run | 18 of 18, 1 not run, 1 limitation | 20 of 20, 1 not run, 1 limitation | 20 of 20, 1 not run, 1 limitation | restart not run: it needs the Docker host |
| 2026-11-03 | Windows 11 Pro, PowerShell 5.1, through SSH tunnels | 22 of 22, 1 not run | 22 of 22, 1 not run | 18 of 18, 1 not run, 1 limitation | 20 of 20, 1 not run, 1 limitation | 20 of 20, 1 not run, 1 limitation | the same; rotation through Git Bash's curl |

The restart checks run only where the store's container runs, so Vigil's recovery after an outage has been seen on Linux only so far. Running them from macOS and Windows, with the Docker host's containers stopped and started remotely, is part of phase 3.
