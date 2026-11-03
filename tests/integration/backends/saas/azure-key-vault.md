# Azure Key Vault: the optional real-cloud test

The emulator tests (`scripts/run-store.sh azure`, against Floci) prove Vigil's requests and how it reads the answers. They prove nothing about Microsoft Entra ID: Floci accepts any client secret and any token. Managed identity was only reached through Vigil's test switch, never Azure's instance metadata service. This guide is the separate, optional test against the real service. **Nobody but you creates anything in Azure.** Nothing in this repository creates subscriptions, vaults, app registrations or role assignments, or accepts terms.

## What only the real service shows

- **Entra ID checks the client secret.** A wrong one fails at `sign-in failed:`.
- **Key Vault checks the token:** its audience (`https://vault.azure.net`), its expiry, and the caller's access through RBAC or access policies.
- **`auth = managed_identity`** gets its token from the instance metadata service on an Azure VM.
- **Real vault names** (`https://<name>.vault.azure.net`) and other clouds' authorities.

## 1. Before you start

- An Azure subscription you control.
- Key Vault charges per operation. Check https://azure.microsoft.com/pricing/details/key-vault/ first, then delete everything afterwards (step 6).

## 2. A vault and test secrets, yourself

Create a vault with the Azure RBAC permission model, for example `vigil-test-kv`, in a resource group of its own. Then add the secrets: `vigil-probe` with a random value, and `vigil-versioned` with two versions. Note the first version's id.

## 3. An app that may read only that vault

An app registration, for example `vigil-test-reader`, with a client secret. On the vault, give it one role assignment: **Key Vault Secrets User**. Give the client secret to Vigil only as a reference, never in a configuration file:

```sh
printf '%s' "$CLIENT_SECRET" | vigil secret set AZURE_TEST_CLIENT_SECRET --stdin
```

## 4. Vigil's configuration

```ini
[secret_store.kv]
type          = azure_keyvault
vault         = https://vigil-test-kv.vault.azure.net
auth          = service_principal
tenant_id     = <tenant id>
client_id     = <the app's client id>
client_secret = secret:AZURE_TEST_CLIENT_SECRET

[job.kv_probe]
file   = scripts/secret.sh                   # tests/integration/backends/workloads
secret = BK_SECRET=store:kv/vigil-probe
env    = BK_SECRET_SHA256=<the probe's SHA-256>
```

## 5. The checks

Run `vigil precheck`, then `vigil run <job>` for each:

| Check | Configuration | Must end |
| --- | --- | --- |
| Sign-in and retrieval | as above | succeeded |
| A chosen version | `store:kv/vigil-versioned/<first version id>` | succeeded, with the first value |
| Missing secret | `store:kv/vigil-nosuch` | `not found (HTTP 404)` |
| A wrong client secret | another value in `AZURE_TEST_CLIENT_SECRET` | `sign-in failed: ...` |
| No access | remove the role assignment, wait for it to apply | `permission denied (HTTP 403)` |
| Managed identity, on an Azure VM only | `auth = managed_identity`, the VM's identity given **Key Vault Secrets User** | succeeded |
| Nothing written down | search Vigil's root for the values and the client secret | nothing found |

Record the results in [`../reports/secrets-compatibility.md`](../reports/secrets-compatibility.md) as **Real cloud**, with the date and the cloud.

## 6. Clean up

Delete the resource group, which takes the vault with it, then purge the vault if soft-delete keeps it. Delete the app registration, and run `vigil secret delete AZURE_TEST_CLIENT_SECRET`.
