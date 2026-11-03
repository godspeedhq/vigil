# 20. Refuse an update when the release key is missing

`vigil self update` only checks the signature if `app/release-key.pem` is there (`app/lib/posix/selfupdate.sh`, `app/lib/windows/SelfUpdate.ps1`). With the file gone it skips the check and carries on, relying on `SHA256SUMS` alone. SPECIFICATION.md 18.7 says a release with a bad or missing signature is refused.

## How much it matters

Low. Every release since 0.2.1 carries the key, so the check is only skipped if someone removes the file, and whoever can do that can already change Vigil. It is still a gap between the code and the specification, in the part of Vigil that most needs to fail closed.

0.1.0 and 0.2.0 have no key, but they run their own older update code, so this change does not affect upgrading from them.

## To do

- Refuse in both twins when the key file is missing, and change nothing.
- Add a test to `self-update.sh` and `Self-Update.ps1`: remove the key, and the update is refused.
- `vigil pack update` already requires a signature, so it needs no change. Confirm that while here.
