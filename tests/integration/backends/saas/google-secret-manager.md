# Google Secret Manager: the optional real-cloud test

The emulator tests (`scripts/run-store.sh gcp`, against Floci) prove Vigil's requests, its signed JWT, and how it reads the answers. They prove nothing about Google's own sign-in: Floci accepts any JWT and has no metadata server. This guide is the separate, optional test against the real service. **Nobody but you creates anything in Google Cloud.** Nothing in this repository creates projects, service accounts, keys or secrets, or accepts terms.

## What only the real service shows

- **Google verifies the JWT** against the service account's key. A key that isn't the account's, or a disabled account, fails at `sign-in failed:`.
- **IAM applies.** Without `roles/secretmanager.secretAccessor` on the secret, the answer is `permission denied (HTTP 403)`.
- **`auth = metadata`** gets its token from the metadata server on a Compute Engine VM, as its service account.

## 1. Before you start

- A Google Cloud project you control, with the Secret Manager API enabled.
- Secret Manager charges for active versions and access operations beyond a free tier. Check https://cloud.google.com/secret-manager/pricing first, then delete everything afterwards (step 6).
- If your organisation forbids service account keys (`iam.disableServiceAccountKeyCreation`), test `auth = metadata` on a VM instead.

## 2. Test secrets, yourself

```sh
printf '%s' "$(openssl rand -hex 16)" | gcloud secrets create vigil-probe --data-file=- --project <project>
printf '%s' "$(openssl rand -hex 16)" | gcloud secrets create vigil-versioned --data-file=- --project <project>
printf '%s' "$(openssl rand -hex 16)" | gcloud secrets versions add vigil-versioned --data-file=- --project <project>
```

## 3. A service account that may read only those

A service account, for example `vigil-test-reader`. Give it `roles/secretmanager.secretAccessor` on those two secrets only, not on the project. Create a JSON key for it, and give the key's contents to Vigil only as a reference, never in a configuration file:

```sh
vigil secret set GCP_TEST_KEY --stdin < key.json
rm key.json
```

## 4. Vigil's configuration

```ini
[secret_store.gsm]
type                = gcp_secret_manager
project             = <project>
auth                = service_account_key
service_account_key = secret:GCP_TEST_KEY

[job.gsm_probe]
file   = scripts/secret.sh                   # tests/integration/backends/workloads
secret = BK_SECRET=store:gsm/vigil-probe
env    = BK_SECRET_SHA256=<the probe's SHA-256>
```

## 5. The checks

Run `vigil precheck`, then `vigil run <job>` for each:

| Check | Configuration | Must end |
| --- | --- | --- |
| Sign-in and retrieval | as above | succeeded |
| A numbered version | `store:gsm/vigil-versioned/1` | succeeded, with the first value |
| Missing secret | `store:gsm/vigil-nosuch` | `not found (HTTP 404)` |
| Not allowed | a secret the account has no role on | `permission denied (HTTP 403)` |
| A key that isn't the account's | another account's key, or a deleted key | `sign-in failed: ...` |
| Metadata, on a Compute Engine VM only | `auth = metadata`, the VM's service account given the same role | succeeded |
| Nothing written down | search Vigil's root for the values and the key's `private_key` | nothing found |

Record the results in [`../reports/secrets-compatibility.md`](../reports/secrets-compatibility.md) as **Real cloud**, with the date and project.

## 6. Clean up

Delete the key and the service account, then the secrets (`gcloud secrets delete`), then run `vigil secret delete GCP_TEST_KEY`.
