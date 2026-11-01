# Signed releases

Each release is signed with a project key, so a compromised release is
caught, not only a corrupted download. `SHA256SUMS` alone cannot do that: it
comes from the same place as the files it checks.

## Scope
- The private key is a GitHub Actions secret; only tagged releases sign.
- The public key is carried in the installers and `vigil self update`.
- Verified with `openssl` on Linux and macOS and .NET on Windows, so hosts
  need nothing new.

## Done when
- A release with a bad or missing signature is refused and changes nothing,
  tested on all three platforms.
