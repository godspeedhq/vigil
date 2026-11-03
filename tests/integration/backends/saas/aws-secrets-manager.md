# AWS Secrets Manager: the optional real-cloud test

The emulator tests (`scripts/run-store.sh aws`, against Floci) prove Vigil's requests and how it reads the answers. They prove nothing about AWS's own sign-in: Floci accepts any key and checks no signature. This guide is the separate, optional test against the real service. **Nobody but you creates anything in AWS.** Nothing in this repository creates accounts, users, roles or secrets, or accepts terms.

## What only the real service shows

- **AWS checks the SigV4 signature.** A wrong secret key gets `permission denied (InvalidSignatureException)`.
- **IAM policies apply.** A secret the user may not read gets `permission denied (AccessDeniedException)`.
- **`auth = instance_profile`** fetches temporary credentials from IMDSv2 on an EC2 instance.
- **Real endpoints:** the regional one, and VPC or FIPS endpoints if you use them.

## 1. Before you start

- An AWS account you control, and a region (here `eu-west-2`).
- Secrets Manager charges per secret per month and per API call. Check https://aws.amazon.com/secrets-manager/pricing/ first, then delete everything afterwards (step 6).

## 2. Create the test secrets, yourself

In the console (**Secrets Manager, then Store a new secret, then Other type of secret, then Plaintext**), or with the AWS CLI:

```sh
aws secretsmanager create-secret --region eu-west-2 --name vigil-test/probe --secret-string "$(openssl rand -hex 16)"
aws secretsmanager create-secret --region eu-west-2 --name vigil-test/json \
    --secret-string "{\"username\":\"vigil\",\"password\":\"$(openssl rand -hex 16)\"}"
```

## 3. A user that may read only those

An IAM user, for example `vigil-test-reader`, with this policy only. Replace the account id:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "secretsmanager:GetSecretValue",
    "Resource": "arn:aws:secretsmanager:eu-west-2:123456789012:secret:vigil-test/*"
  }]
}
```

Create an access key for it. Give the secret key to Vigil only as a reference, never in a configuration file:

```sh
printf '%s' "$SECRET_ACCESS_KEY" | vigil secret set AWS_TEST_SECRET_KEY --stdin
```

## 4. Vigil's configuration

```ini
[secret_store.aws]
type              = aws_secrets_manager
region            = eu-west-2
auth              = access_keys
access_key_id     = AKIA...                  # not secret: written as is
secret_access_key = secret:AWS_TEST_SECRET_KEY

[job.aws_probe]
file   = scripts/secret.sh                   # tests/integration/backends/workloads
secret = BK_SECRET=store:aws/vigil-test/probe
env    = BK_SECRET_SHA256=<the probe's SHA-256>
```

`vigil-test/probe` is the secret's name in AWS; everything after `aws/` is passed as written.

## 5. The checks

Run `vigil precheck`, then `vigil run <job>` for each:

| Check | Configuration | Must end |
| --- | --- | --- |
| Retrieval | as above | succeeded |
| A JSON key | `field = password`, `store:aws/vigil-test/json` | succeeded |
| Missing secret | `store:aws/vigil-test/nosuch` | `not found (ResourceNotFoundException)` |
| A wrong secret key | another value in `AWS_TEST_SECRET_KEY` | `permission denied (InvalidSignatureException)` |
| Not allowed | a secret outside `vigil-test/*` | `permission denied (AccessDeniedException)` |
| Instance profile, on EC2 only | `auth = instance_profile`, with the instance role given the policy above | succeeded |
| Nothing written down | search Vigil's root for the values and the key | nothing found |

Record the results in [`../reports/secrets-compatibility.md`](../reports/secrets-compatibility.md) as **Real cloud**, with the date and region.

## 6. Clean up

Delete the access key, the IAM user and its policy, and the secrets (`aws secretsmanager delete-secret --force-delete-without-recovery`), then run `vigil secret delete AWS_TEST_SECRET_KEY`.
