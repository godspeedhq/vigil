# Vendor CLI first, curl and openssl second: the `client` key

For `azure_keyvault`, `aws_secrets_manager` and `gcp_secret_manager`, use the
vendor's CLI (`az`, `aws`, `gcloud`) when it is installed, else Vigil's own
HTTPS client. Said plainly in the config and the docs.

## Scope
- `client = auto` (default) | `cli` | `http`.
- The CLI only where it signs in without writing a credential to disk:
  - aws: `instance_profile`; `access_keys` passed as environment variables.
  - gcloud: `metadata` only (`service_account_key` needs a key file).
  - az: `managed_identity`, after `az login --identity` as the service account.
  - `client = cli` with any other method is a validation error.
- Run directly, never through a shell, within the store's `timeout`.
- `vigil precheck` prints which client each store uses and why.
- Docs state the prerequisite plainly: for `client = cli`, the vendor CLI is
  required on the server; for `http`, curl (and openssl for AWS and GCP).

## Done when
- Validation and conformance cases for `client`, both twins.
- Integration tests with fake `az`/`aws`/`gcloud` commands, both twins.
