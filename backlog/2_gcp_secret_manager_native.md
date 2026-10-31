# GCP Secret Manager, built in

`store:` references to `gcp_secret_manager` resolve over HTTPS with curl and
openssl on Linux and macOS, and .NET on Windows. No gcloud needed.

## Scope
- `auth = metadata`: a token from the metadata server
  (`metadata.google.internal`, header `Metadata-Flavor: Google`), never proxied.
- `auth = service_account_key`: a reference to the key JSON; a JWT signed
  RS256 (openssl on stdin, .NET RSA on Windows) exchanged for a token.
- `GET .../projects/<project>/secrets/<NAME>/versions/latest:access`;
  `NAME/<version>` picks a version. The payload is base64: decoded.

## Done when
- Conformance cases for requests, JWT building and reasons, both twins.
- Integration test against the mock, both twins, every shell in CI.
- Spec 6.5.3 and README updated.
