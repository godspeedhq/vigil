# AWS Secrets Manager, built in

`store:` references to `aws_secrets_manager` resolve over HTTPS with curl and
openssl on Linux and macOS, and .NET on Windows. No AWS CLI needed.

## Scope
- `auth = instance_profile`: credentials from the instance metadata service,
  IMDSv2 (session token first), plain http to 169.254.169.254, never proxied.
- `auth = access_keys`: `access_key_id` and `secret_access_key` references.
- `GetSecretValue` (`POST` to `secretsmanager.<region>.amazonaws.com`), signed
  with SigV4: HMAC-SHA256 with `openssl` (not curl's `--aws-sigv4`, which
  RHEL 8's curl 7.61 lacks), .NET on Windows.
- `SecretString` as the value; optional `field` picks one key of a JSON secret.
- The secret key never on a command line: openssl gets it on stdin.

## Done when
- Conformance cases: canonical request, string to sign and signature against
  AWS's published SigV4 test vectors; every request and reason, both twins.
- Integration test against the mock, both twins, every shell in CI.
- Spec 6.5.3 and README updated; `openssl` listed as a prerequisite on
  Linux and macOS.
