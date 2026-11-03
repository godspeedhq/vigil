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
| Floci Azure | Docker | Emulator | Not tested | Not tested | Not tested | Not tested | Not tested (phase 2) |
| Azure Key Vault emulator (community) | Docker | Emulator | Not tested | Not tested | Not tested | Not tested | Not tested (phase 2) |
| Floci GCP | Docker | Emulator | Not tested | Not tested | Not tested | Not tested | Not tested (phase 2) |
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

## Runs

| Date | Vigil on | OpenBao | Vault | Floci AWS | Notes |
| --- | --- | --- | --- | --- | --- |
| 2026-11-03 | Fedora 44 (the Docker host), bash 5.3 | 26 of 26 | 26 of 26 | 20 of 20, 1 emulator limitation | restart and recovery included |
| 2026-11-03 | macOS 12.7.6, bash 3.2, through SSH tunnels | 22 of 22, 1 not run | 22 of 22, 1 not run | 18 of 18, 1 not run, 1 emulator limitation | restart not run: it needs the Docker host |
| 2026-11-03 | Windows 11 Pro, PowerShell 5.1, through SSH tunnels | 22 of 22, 1 not run | 22 of 22, 1 not run | 18 of 18, 1 not run, 1 emulator limitation | the same; rotation through Git Bash's curl |

The restart checks run only where the store's container runs, so Vigil's recovery after an outage has been seen on Linux only so far. Running them from macOS and Windows, with the Docker host's containers stopped and started remotely, is part of phase 3.
